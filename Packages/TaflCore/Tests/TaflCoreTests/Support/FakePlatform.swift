import Foundation
import Synchronization
@testable import TaflCore

/// Holds one call of a `FakePlatform` until `open()`.
final class FakeGate: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: Void.self)
    }

    func open() {
        continuation.finish()
    }

    fileprivate func wait() async {
        for await _ in stream {}
    }
}

/// A scripted platform. Every write-session call is logged as `"begin"`, `"size <w>x<h>"`,
/// `"position <x>,<y>"`, `"read"` or `"end"`. Call indices count those calls from 0, in the
/// order they start executing: after a session slot is acquired and before the gate, hook
/// and log entry for that call.
actor FakePlatform: WindowPlatform {
    struct UnobservedApp: Equatable, Sendable {
        var pid: Int32
        var bundleID: String?
        var missing: Set<ObservedEvent>
    }

    var windows: [WindowHandle: WindowSnapshot] = [:]
    var focused: WindowHandle?
    var displays: [Display]
    var pointer: DisplayIdentity?
    var tiling = TilingSettings(edgeDrag: false, optionAccelerator: false, topEdgeDrag: false, tiledMargins: nil)
    var accessibilityGranted = true
    var capabilityStates: [CapabilityState] = []
    var sizeRule: (@Sendable (WindowSnapshot, ScreenSize) -> ScreenSize)?
    var positionRule: (@Sendable (WindowSnapshot, ScreenPoint) -> ScreenPoint)?
    var beforeCall: [Int: @Sendable (inout WindowSnapshot) -> Void] = [:]
    var hung: Set<Int32> = []
    var unobserved: [UnobservedApp] = []

    private(set) var callLog: [String] = []
    private(set) var startObservingCount = 0
    private(set) var stopObservingCount = 0

    nonisolated let events: AsyncStream<PlatformEvent>
    private nonisolated let eventSink: AsyncStream<PlatformEvent>.Continuation

    private let clock: any TaflClock
    private var callCount = 0
    private var gates: [Int: FakeGate] = [:]
    private var busyPids: Set<Int32> = []
    private var waiters: [Int32: [CheckedContinuation<Void, Never>]] = [:]

    init(clock: any TaflClock, displays: [Display] = [displayA]) {
        self.clock = clock
        self.displays = displays
        (events, eventSink) = AsyncStream.makeStream(of: PlatformEvent.self)
    }

    /// Changes the fake's state from outside the actor: `await fake.configure { $0.focused = h }`.
    func configure(_ body: @Sendable (isolated FakePlatform) -> Void) {
        body(self)
    }

    func emit(_ event: PlatformEvent) {
        eventSink.yield(event)
    }

    /// Emits an `.unobservable` event for each entry in `unobserved`.
    func emitUnobserved() {
        for app in unobserved {
            emit(.unobservable(pid: app.pid, bundleID: app.bundleID, missing: app.missing))
        }
    }

    /// Holds the call with this index until the returned gate opens.
    func pause(beforeCall index: Int) -> FakeGate {
        let gate = FakeGate()
        gates[index] = gate
        return gate
    }

    // MARK: WindowPlatform

    func displays() async -> [Display] { displays }

    func focusedWindow() async -> Result<WindowSnapshot, PlatformFailure> {
        guard let focused else { return .failure(.noWindow) }
        return await snapshot(of: focused)
    }

    func visibleWindows() async -> [WindowSnapshot] {
        windows.values.sorted { ($0.handle.pid, $0.handle.windowID) < ($1.handle.pid, $1.handle.windowID) }
    }

    func snapshot(of handle: WindowHandle) async -> Result<WindowSnapshot, PlatformFailure> {
        if hung.contains(handle.pid) {
            try? await clock.sleep(for: .milliseconds(500))
            return .failure(.notResponding)
        }
        guard let window = windows[handle] else { return .failure(.noWindow) }
        return .success(window)
    }

    func beginWriting(_ handle: WindowHandle) async -> Result<any WriteSession, PlatformFailure> {
        await acquireSlot(handle.pid)
        if await enter(handle, "begin") {
            releaseSlot(handle.pid)
            return .failure(.notResponding)
        }
        guard windows[handle] != nil else {
            releaseSlot(handle.pid)
            return .failure(.noWindow)
        }
        return .success(FakeSession(platform: self, handle: handle))
    }

    func pointerDisplay() async -> DisplayIdentity? { pointer }

    func tilingSettings() async -> TilingSettings { tiling }

    func isAccessibilityGranted() async -> Bool { accessibilityGranted }

    func capabilities() async -> [CapabilityState] { capabilityStates }

    func startObserving() async { startObservingCount += 1 }

    func stopObserving() async { stopObservingCount += 1 }

    // MARK: Session calls

    fileprivate func read(_ handle: WindowHandle) async -> Result<ScreenRect, PlatformFailure> {
        if await enter(handle, "read") { return .failure(.notResponding) }
        guard let window = windows[handle] else { return .failure(.noWindow) }
        return .success(window.frame)
    }

    fileprivate func writeSize(_ handle: WindowHandle, _ size: ScreenSize) async -> Result<Void, PlatformFailure> {
        if await enter(handle, "size \(format(size.width))x\(format(size.height))") {
            return .failure(.notResponding)
        }
        guard var window = windows[handle] else { return .failure(.noWindow) }
        if window.canResize {
            window.frame.size = sizeRule?(window, size) ?? size
            windows[handle] = window
        }
        return .success(())
    }

    fileprivate func writePosition(_ handle: WindowHandle, _ point: ScreenPoint) async -> Result<Void, PlatformFailure> {
        if await enter(handle, "position \(format(point.x)),\(format(point.y))") {
            return .failure(.notResponding)
        }
        guard var window = windows[handle] else { return .failure(.noWindow) }
        guard window.canMove else { return .failure(.cannotMove) }
        window.frame.origin = positionRule?(window, point) ?? point
        windows[handle] = window
        return .success(())
    }

    fileprivate func finish(_ handle: WindowHandle) async {
        _ = await enter(handle, "end", waitsWhenHung: false)
        releaseSlot(handle.pid)
    }

    // MARK: Mechanics

    /// Claims the next call index, waits for its gate, logs the call, runs its hook and, for a
    /// hung app, waits 0.5 s on the clock. Returns true when the app is hung.
    private func enter(_ handle: WindowHandle, _ entry: String, waitsWhenHung: Bool = true) async -> Bool {
        let index = callCount
        callCount += 1
        if let gate = gates.removeValue(forKey: index) { await gate.wait() }
        callLog.append(entry)
        if let hook = beforeCall[index], var window = windows[handle] {
            hook(&window)
            windows[handle] = window
        }
        guard waitsWhenHung, hung.contains(handle.pid) else { return false }
        try? await clock.sleep(for: .milliseconds(500))
        return true
    }

    private func acquireSlot(_ pid: Int32) async {
        guard busyPids.contains(pid) else {
            busyPids.insert(pid)
            return
        }
        await withCheckedContinuation { waiters[pid, default: []].append($0) }
    }

    private func releaseSlot(_ pid: Int32) {
        if var queue = waiters[pid], !queue.isEmpty {
            queue.removeFirst().resume()
            waiters[pid] = queue.isEmpty ? nil : queue
        } else {
            busyPids.remove(pid)
        }
    }

    private func format(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }
}

private final class FakeSession: WriteSession {
    private let platform: FakePlatform
    private let handle: WindowHandle
    private let ended = Mutex(false)

    init(platform: FakePlatform, handle: WindowHandle) {
        self.platform = platform
        self.handle = handle
    }

    func readFrame() async -> Result<ScreenRect, PlatformFailure> {
        await platform.read(handle)
    }

    func setSize(_ size: ScreenSize) async -> Result<Void, PlatformFailure> {
        await platform.writeSize(handle, size)
    }

    func setPosition(_ point: ScreenPoint) async -> Result<Void, PlatformFailure> {
        await platform.writePosition(handle, point)
    }

    func end() async {
        let isFirst = ended.withLock { ended in
            defer { ended = true }
            return !ended
        }
        if isFirst { await platform.finish(handle) }
    }
}
