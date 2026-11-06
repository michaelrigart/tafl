import Foundation
import Synchronization
import Testing
@testable import TaflCore

/// Holds one call of a `FakePlatform` until `open()`. A cancelled caller keeps waiting: a real
/// Accessibility call in flight cannot be cancelled.
final class FakeGate: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    /// How many calls are held at this gate.
    var waiterCount: Int { state.withLock { $0.waiters.count } }

    func open() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isOpen = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    fileprivate func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyOpen = state.withLock { state in
                if !state.isOpen { state.waiters.append(continuation) }
                return state.isOpen
            }
            if alreadyOpen { continuation.resume() }
        }
    }
}

/// A scripted platform. Every read is stamped with `ContinuousClock.now` as it is made, so a
/// snapshot or read-back carries when it was read, whatever `windows` holds. Every write-session
/// call is logged as `"begin"`, `"size <w>x<h>"`,
/// `"position <x>,<y>"`, `"read"` or `"end"`. Call indices count those calls from 0, in the
/// order they start (a `beginWriting` that waits for its app's session slot starts once it has
/// the slot). A call keeps its index while it is held: a gated call is logged only when its gate
/// opens, so another app's calls that start later may log ahead of it.
///
/// Tests wait on an observable condition (`waitUntil`, a log entry, a clock's sleeper count or
/// `task.value`), never on a yield budget.
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
    var tiling = TilingSettings(edgeDrag: nil, optionAccelerator: nil, topEdgeDrag: nil, tiledMargins: nil)
    var accessibilityGranted = true
    var capabilityStates: [CapabilityState] = []
    var sizeRule: (@Sendable (WindowSnapshot, ScreenSize) -> ScreenSize)?
    var positionRule: (@Sendable (WindowSnapshot, ScreenPoint) -> ScreenPoint)?
    var beforeCall: [Int: @Sendable (inout WindowSnapshot) -> Void] = [:]
    var hung: Set<Int32> = []
    /// App names by process id; a pid not listed falls back to the name of one of its windows.
    var appNames: [Int32: String] = [:]
    /// Launch dates by process id. A pid not listed is running since long ago while it has a
    /// window, and is not running otherwise.
    var launched: [Int32: Date] = [:]
    var unobserved: [UnobservedApp] = []

    private(set) var callLog: [String] = []
    /// Holds the next `displays()` call until the gate opens.
    var displaysGate: FakeGate?
    /// Holds the next `visibleWindows()` call until the gate opens.
    var visibleWindowsGate: FakeGate?
    /// Holds the next `startObserving()` call until the gate opens.
    var startObservingGate: FakeGate?
    /// Reads the windows, then holds the result of the next `visibleWindows()` until the gate opens.
    var visibleWindowsLateGate: FakeGate?
    /// Holds the next `snapshot(of:)` call until the gate opens.
    var snapshotGate: FakeGate?
    /// Reads the window, then holds the result of the next `snapshot(of:)` until the gate opens.
    var snapshotLateGate: FakeGate?
    /// How many `snapshot(of:)` calls have started.
    private(set) var snapshotCount = 0
    private var snapshotGates: [Int: FakeGate] = [:]
    private var visibleWindowsCount = 0
    private var visibleWindowsResultGates: [Int: FakeGate] = [:]

    /// How many `beginWriting` calls wait for another session of the same app to end.
    var waitingSessionCount: Int { waiters.values.reduce(0) { $0 + $1.count } }
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

    /// Waits until `condition` holds, polling with `Task.yield()`. Records an issue after
    /// `timeout` of wall-clock time.
    func waitUntil(
        timeout: Duration = .seconds(2),
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: @Sendable (isolated FakePlatform) -> Bool
    ) async {
        let start = ContinuousClock.now
        while !condition(self) {
            if start.duration(to: ContinuousClock.now) > timeout {
                Issue.record("Timed out waiting for a FakePlatform condition", sourceLocation: sourceLocation)
                return
            }
            await Task.yield()
        }
    }

    /// Holds the `snapshot(of:)` call with this index, counted from 0, until the returned gate opens.
    func pauseSnapshot(at index: Int) -> FakeGate {
        let gate = FakeGate()
        snapshotGates[index] = gate
        return gate
    }

    /// Reads the windows for the `visibleWindows()` call with this index, counted from 0, then holds
    /// its result until the returned gate opens.
    func pauseVisibleWindowsResult(at index: Int) -> FakeGate {
        let gate = FakeGate()
        visibleWindowsResultGates[index] = gate
        return gate
    }

    /// Holds the call with this index until the returned gate opens.
    func pause(beforeCall index: Int) -> FakeGate {
        let gate = FakeGate()
        gates[index] = gate
        return gate
    }

    // MARK: WindowPlatform

    func displays() async -> [Display] {
        if let gate = displaysGate {
            displaysGate = nil
            await gate.wait()
        }
        return displays
    }

    func focusedWindow() async -> Result<WindowSnapshot, PlatformFailure> {
        guard let focused else { return .failure(.noWindow) }
        return await snapshot(of: focused)
    }

    func visibleWindows() async -> [WindowSnapshot] {
        let index = visibleWindowsCount
        visibleWindowsCount += 1
        if let gate = visibleWindowsGate {
            visibleWindowsGate = nil
            await gate.wait()
        }
        let read = windows.values
            .sorted { ($0.handle.pid, $0.handle.windowID) < ($1.handle.pid, $1.handle.windowID) }
            .map(stamped)
        if let late = visibleWindowsLateGate {
            visibleWindowsLateGate = nil
            await late.wait()
        }
        if let late = visibleWindowsResultGates.removeValue(forKey: index) { await late.wait() }
        return read
    }

    func snapshot(of handle: WindowHandle) async -> Result<WindowSnapshot, PlatformFailure> {
        let index = snapshotCount
        snapshotCount += 1
        if let gate = snapshotGates.removeValue(forKey: index) { await gate.wait() }
        if let gate = snapshotGate {
            snapshotGate = nil
            await gate.wait()
        }
        if hung.contains(handle.pid) {
            await hungWait()
            return .failure(.notResponding)
        }
        guard let window = windows[handle] else { return .failure(.noWindow) }
        let read = stamped(window)
        if let late = snapshotLateGate {
            snapshotLateGate = nil
            await late.wait()
        }
        return .success(read)
    }

    func appName(pid: Int32) async -> String? {
        appNames[pid] ?? windows.values.first { $0.handle.pid == pid }?.appName
    }

    func launchDates(of pids: Set<Int32>) async -> [Int32: Date] {
        var dates: [Int32: Date] = [:]
        for pid in pids {
            if let date = launched[pid] {
                dates[pid] = date
            } else if windows.values.contains(where: { $0.handle.pid == pid }) {
                dates[pid] = .distantPast
            }
        }
        return dates
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

    func startObserving() async -> [UnobservableApp] {
        startObservingCount += 1
        if let gate = startObservingGate {
            startObservingGate = nil
            await gate.wait()
        }
        return unobserved.map { UnobservableApp(pid: $0.pid, bundleID: $0.bundleID, missing: $0.missing) }
    }

    func stopObserving() async { stopObservingCount += 1 }

    // MARK: Session calls

    fileprivate func read(_ handle: WindowHandle) async -> Result<FrameReading, PlatformFailure> {
        if await enter(handle, "read") { return .failure(.notResponding) }
        guard let window = windows[handle] else { return .failure(.noWindow) }
        return .success(FrameReading(frame: window.frame, readAt: .now))
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
        _ = await enter(handle, "end")
        releaseSlot(handle.pid)
    }

    // MARK: Mechanics

    private func stamped(_ window: WindowSnapshot) -> WindowSnapshot {
        var read = window
        read.readAt = .now
        return read
    }

    /// Claims the next call index, waits for its gate, logs the call, runs its hook and, for a
    /// hung app, waits 0.5 s on the clock. Returns true when the app is hung.
    private func enter(_ handle: WindowHandle, _ entry: String) async -> Bool {
        let index = callCount
        callCount += 1
        if let gate = gates.removeValue(forKey: index) { await gate.wait() }
        callLog.append(entry)
        if let hook = beforeCall[index], var window = windows[handle] {
            hook(&window)
            windows[handle] = window
        }
        guard hung.contains(handle.pid) else { return false }
        await hungWait()
        return true
    }

    /// A call in flight cannot be cancelled, so the wait runs in an unstructured task that
    /// does not inherit the caller's cancellation.
    private func hungWait() async {
        let clock = clock
        await Task { try? await clock.sleep(for: .milliseconds(500)) }.value
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

    func readFrame() async -> Result<FrameReading, PlatformFailure> {
        if usedAfterEnd() { return .failure(.cannotMove) }
        return await platform.read(handle)
    }

    func setSize(_ size: ScreenSize) async -> Result<Void, PlatformFailure> {
        if usedAfterEnd() { return .failure(.cannotMove) }
        return await platform.writeSize(handle, size)
    }

    func setPosition(_ point: ScreenPoint) async -> Result<Void, PlatformFailure> {
        if usedAfterEnd() { return .failure(.cannotMove) }
        return await platform.writePosition(handle, point)
    }

    func end() async {
        let isFirst = ended.withLock { ended in
            defer { ended = true }
            return !ended
        }
        if isFirst { await platform.finish(handle) }
    }

    private func usedAfterEnd() -> Bool {
        let isEnded = ended.withLock { $0 }
        if isEnded { Issue.record("A write session was used after end()") }
        return isEnded
    }
}
