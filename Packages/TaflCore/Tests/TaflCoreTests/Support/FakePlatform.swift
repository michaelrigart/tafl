import Foundation
import Synchronization
import Testing
import TaflTestSupport
@testable import TaflCore

/// A scripted platform. A read hands what it read to the caller's `take` in the same actor step, as
/// the platform does inside its app's queue: a gate that holds a read's result holds it after `take`
/// has run. A write asks its `admit` in the same step as the write, after its gate: a read made while
/// the gate holds the write is one the app's queue holds ahead of it. A position write first asks
/// whether the position is settable, as the platform does, and the gate holds that query: a hung
/// app times it out, and a window that cannot be moved fails it, each without the write being
/// admitted. The admission is the last step before the write.
///
/// Every write-session call is logged as `"begin"`, `"size <w>x<h>"`, `"position <x>,<y>"`,
/// `"read"` or `"end"`; a write that `admit` does not allow is logged with its answer, as in
/// `"size <w>x<h> interrupted"`, and changes nothing. Call indices count those calls from 0, in
/// the order they start (a `beginWriting` that waits for its app's session slot starts once it has
/// the slot). A call keeps its index while it is held: a gated call is logged only when its gate
/// opens, so another app's calls that start later may log ahead of it.
///
/// A call held at a gate parks the engine's task that made it (`EngineActivity`), so a test can wait
/// for the engine to be quiescent while the gate holds. Gates are `Gate`s, which need a `.gated` test.
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
    /// What the next registration of each app misses: `startObserving` and `observeAgain(pids:)` answer
    /// from it, and publish it as the app's outcome. An app not listed observes fully.
    var unobserved: [UnobservedApp] = []
    /// What each app's current registration misses, as its latest outcome event said. The fake
    /// announces a window only while that observes placement, as the platform does.
    private(set) var current: [Int32: Set<ObservedEvent>] = [:]

    private(set) var callLog: [String] = []
    /// The windows each `raise(_:)` call was given, in order. Not part of `callLog`.
    private(set) var raiseCalls: [[WindowHandle]] = []
    /// The windows actually raised, in order, across every `raise(_:admit:)` call: the last is on top.
    private(set) var raised: [WindowHandle] = []
    private struct RaiseStep: Hashable {
        var call: Int
        var step: Int
    }
    private var raiseGates: [RaiseStep: Gate] = [:]
    private var beginGates: [WindowHandle: Gate] = [:]
    /// Holds the next `displays()` call until the gate opens.
    var displaysGate: Gate?
    /// Holds the next `visibleWindows()` call until the gate opens.
    var visibleWindowsGate: Gate?
    /// Holds the next `startObserving(notices:)` call, once it has published its outcomes, until the
    /// gate opens.
    var startObservingGate: Gate?
    /// Holds the next `observeAgain(pids:)` call, once it has published its outcomes, until the gate opens.
    var observeAgainGate: Gate?
    /// The windows an `observeAgain(pids:)` that registers an app announces, after its outcome, as the
    /// platform's catch-up does, before the call returns.
    var observeAgainAnnounces: [WindowSnapshot] = []
    /// Reads the windows, then holds the result of the next `visibleWindows()` until the gate opens.
    var visibleWindowsLateGate: Gate?
    /// Holds the next `snapshot(of:)` call until the gate opens.
    var snapshotGate: Gate?
    /// Reads the window, then holds the result of the next `snapshot(of:)` until the gate opens.
    var snapshotLateGate: Gate?
    /// How many `snapshot(of:)` calls have started.
    private(set) var snapshotCount = 0
    private var snapshotGates: [Int: Gate] = [:]
    private var visibleWindowsCount = 0
    private var visibleWindowsResultGates: [Int: Gate] = [:]

    /// How many `beginWriting` calls wait for another session of the same app to end.
    var waitingSessionCount: Int { waiters.values.reduce(0) { $0 + $1.count } }
    private(set) var startObservingCount = 0
    private(set) var stopObservingCount = 0
    /// The pids each `observeAgain(pids:)` call was given, in order.
    private(set) var observeAgainCalls: [Set<Int32>] = []
    /// What the last `startObserving(notices:)` was given.
    private var notices: (any WindowNotices)?
    /// How many events the fake has sent, for a test to wait until the engine has received them all.
    private(set) var eventsSent = 0

    nonisolated let events: AsyncStream<PlatformEvent>
    private nonisolated let eventSink: AsyncStream<PlatformEvent>.Continuation

    private let clock: ManualClock
    private var callCount = 0
    private var gates: [Int: Gate] = [:]
    private var busyPids: Set<Int32> = []
    private var waiters: [Int32: [Gate]] = [:]

    init(clock: ManualClock, displays: [Display] = [displayA]) {
        self.clock = clock
        self.displays = displays
        (events, eventSink) = AsyncStream.makeStream(of: PlatformEvent.self)
    }

    /// Changes the fake's state from outside the actor: `await fake.configure { $0.focused = h }`.
    func configure(_ body: @Sendable (isolated FakePlatform) -> Void) {
        body(self)
    }

    /// Emits an event as the platform does: a window's announcement, end or app's quit reaches the
    /// notices first, in the same step. A window is announced only while its app's current registration
    /// observes placement; an outcome makes the registration it reports the app's current one.
    func emit(_ event: PlatformEvent) {
        switch event {
        case .windowCreated(let snapshot):
            guard current[snapshot.handle.pid, default: []].isDisjoint(with: [.created, .moved, .resized, .destroyed])
            else { return }
            notices?.announced(snapshot)
        case .windowDestroyed(let window): notices?.destroyed(window)
        case .appQuit(let pid):
            current[pid] = nil
            notices?.quit(pid: pid)
        case .observability(let pid, _, let missing, _): current[pid] = missing
        default: break
        }
        send(event)
    }

    /// Reads a window for its announcement, as a catch-up does long before its event arrives:
    /// `deliver` sends the event later.
    func announce(_ snapshot: WindowSnapshot) {
        notices?.announced(snapshot)
    }

    /// Sends an event without telling the notices: the delivery of one announced earlier.
    func deliver(_ event: PlatformEvent) {
        send(event)
    }

    private func send(_ event: PlatformEvent) {
        eventsSent += 1
        eventSink.yield(event)
    }

    /// Holds the `snapshot(of:)` call with this index, counted from 0, until the returned gate opens.
    func pauseSnapshot(at index: Int) -> Gate {
        let gate = Gate()
        snapshotGates[index] = gate
        return gate
    }

    /// Reads the windows for the `visibleWindows()` call with this index, counted from 0, then holds
    /// its result until the returned gate opens.
    func pauseVisibleWindowsResult(at index: Int) -> Gate {
        let gate = Gate()
        visibleWindowsResultGates[index] = gate
        return gate
    }

    /// Holds the `beginWriting` call for this window until the returned gate opens: before it takes
    /// its app's session slot, and without a call index.
    func pauseBeginning(_ handle: WindowHandle) -> Gate {
        let gate = Gate()
        beginGates[handle] = gate
        return gate
    }

    /// Holds the call with this index until the returned gate opens.
    func pause(beforeCall index: Int) -> Gate {
        let gate = Gate()
        gates[index] = gate
        return gate
    }

    // MARK: WindowPlatform

    func displays() async -> [Display] {
        if let gate = displaysGate {
            displaysGate = nil
            await hold(gate)
        }
        return displays
    }

    func focusedWindow<T: Sendable>(take: @escaping @Sendable (WindowSnapshot) -> T) async -> Result<T, PlatformFailure> {
        guard let focused else { return .failure(.noWindow) }
        return await snapshot(of: focused, take: take)
    }

    /// Each window is handed to `take` as it is read, before any gate that holds the result.
    func visibleWindows<T: Sendable>(take: @escaping @Sendable (WindowSnapshot) -> T) async -> [T] {
        let index = visibleWindowsCount
        visibleWindowsCount += 1
        if let gate = visibleWindowsGate {
            visibleWindowsGate = nil
            await hold(gate)
        }
        let read = windows.values
            .sorted { ($0.handle.pid, $0.handle.windowID) < ($1.handle.pid, $1.handle.windowID) }
            .map(take)
        if let late = visibleWindowsLateGate {
            visibleWindowsLateGate = nil
            await hold(late)
        }
        if let late = visibleWindowsResultGates.removeValue(forKey: index) { await hold(late) }
        return read
    }

    /// The window is handed to `take` as it is read, before any gate that holds the result.
    func snapshot<T: Sendable>(
        of handle: WindowHandle,
        take: @escaping @Sendable (WindowSnapshot) -> T
    ) async -> Result<T, PlatformFailure> {
        let index = snapshotCount
        snapshotCount += 1
        if let gate = snapshotGates.removeValue(forKey: index) { await hold(gate) }
        if let gate = snapshotGate {
            snapshotGate = nil
            await hold(gate)
        }
        if hung.contains(handle.pid) {
            await hungWait()
            return .failure(.notResponding)
        }
        guard let window = windows[handle] else { return .failure(.noWindow) }
        let read = take(window)
        if let late = snapshotLateGate {
            snapshotLateGate = nil
            await hold(late)
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
        if let gate = beginGates.removeValue(forKey: handle) { await hold(gate) }
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

    /// Each window is one step: it waits for its gate, asks `admit` in the same step, and is raised
    /// only when `admit` allows it. A refused step ends the call.
    func raise(_ windows: [WindowHandle], admit: @escaping @Sendable () -> Bool) async {
        let call = raiseCalls.count
        raiseCalls.append(windows)
        for (step, window) in windows.enumerated() {
            if let gate = raiseGates.removeValue(forKey: RaiseStep(call: call, step: step)) { await hold(gate) }
            guard admit() else { return }
            raised.append(window)
        }
    }

    /// Holds the `raise` call with this index, counted from 0, before its step with this index.
    func pauseRaise(call: Int, beforeStep step: Int) -> Gate {
        let gate = Gate()
        raiseGates[RaiseStep(call: call, step: step)] = gate
        return gate
    }

    func pointerDisplay() async -> DisplayIdentity? { pointer }

    func tilingSettings() async -> TilingSettings { tiling }

    func isAccessibilityGranted() async -> Bool { accessibilityGranted }

    func capabilities() async -> [CapabilityState] { capabilityStates }

    /// Registers every app as the platform does, each publishing its outcome before the call returns:
    /// an app in `unobserved` misses what it lists, and one whose registration missed something before
    /// observes fully now. The apps in `unobserved` are the answer.
    func startObserving(notices: any WindowNotices) async -> [UnobservableApp] {
        self.notices = notices
        startObservingCount += 1
        let answer = unobserved.map { UnobservableApp(pid: $0.pid, bundleID: $0.bundleID, missing: $0.missing) }
        let recovered = current.filter { !$0.value.isEmpty && !answer.map(\.pid).contains($0.key) }.keys
        for pid in recovered.sorted() { emit(.observability(pid: pid, bundleID: nil, missing: [], retrying: false)) }
        for app in answer { emit(.observability(pid: app.pid, bundleID: app.bundleID, missing: app.missing, retrying: false)) }
        if let gate = startObservingGate {
            startObservingGate = nil
            await hold(gate)
        }
        return answer
    }

    /// Registers each app again as `startObserving` does, answering from `unobserved`: a test changes it
    /// to say what a retry finds. An app that registers then has `observeAgainAnnounces` announced.
    func observeAgain(pids: Set<Int32>) async -> [UnobservableApp] {
        observeAgainCalls.append(pids)
        let answer = unobserved.filter { pids.contains($0.pid) }
            .map { UnobservableApp(pid: $0.pid, bundleID: $0.bundleID, missing: $0.missing) }
        for pid in pids.sorted() {
            let found = answer.first { $0.pid == pid }
            emit(.observability(pid: pid, bundleID: found?.bundleID, missing: found?.missing ?? [], retrying: false))
            guard found == nil else { continue }
            for snapshot in observeAgainAnnounces where snapshot.handle.pid == pid { emit(.windowCreated(snapshot)) }
        }
        if let gate = observeAgainGate {
            observeAgainGate = nil
            await hold(gate)
        }
        return answer
    }

    func stopObserving() async { stopObservingCount += 1 }

    // MARK: Session calls

    fileprivate func read<T: Sendable>(
        _ handle: WindowHandle,
        take: @Sendable (ScreenRect) -> T
    ) async -> Result<T, PlatformFailure> {
        if await enter(handle, "read") { return .failure(.notResponding) }
        guard let window = windows[handle] else { return .failure(.noWindow) }
        return .success(take(window.frame))
    }

    fileprivate func writeSize(
        _ handle: WindowHandle,
        _ size: ScreenSize,
        admit: @Sendable () -> WriteGo
    ) async -> Result<WriteGo, PlatformFailure> {
        await write(handle, "size \(format(size.width))x\(format(size.height))", queriesSettability: false, admit: admit) { window in
            if window.canResize { window.frame.size = sizeRule?(window, size) ?? size }
            return .success(())
        }
    }

    fileprivate func writePosition(
        _ handle: WindowHandle,
        _ point: ScreenPoint,
        admit: @Sendable () -> WriteGo
    ) async -> Result<WriteGo, PlatformFailure> {
        await write(handle, "position \(format(point.x)),\(format(point.y))", queriesSettability: true, admit: admit) { window in
            window.frame.origin = positionRule?(window, point) ?? point
            return .success(())
        }
    }

    fileprivate func finish(_ handle: WindowHandle) async {
        _ = await enter(handle, "end")
        releaseSlot(handle.pid)
    }

    // MARK: Mechanics

    /// Claims the next call index, waits for its gate, logs the call, runs its hook and, for a
    /// hung app, waits 0.5 s on the clock. Returns true when the app is hung.
    private func enter(_ handle: WindowHandle, _ entry: String) async -> Bool {
        await claim(handle)
        callLog.append(entry)
        guard hung.contains(handle.pid) else { return false }
        await hungWait()
        return true
    }

    /// A write: its call is claimed as `enter` does. A write that queries settability does so next:
    /// a hung app times out after 0.5 s on the clock, and a window that cannot be moved is refused,
    /// neither admitted. Then `admit` is asked in the same step as the write. A hung app's size
    /// write is admitted, then fails after 0.5 s on the clock without changing the window.
    private func write(
        _ handle: WindowHandle,
        _ entry: String,
        queriesSettability: Bool,
        admit: @Sendable () -> WriteGo,
        _ apply: (inout WindowSnapshot) -> Result<Void, PlatformFailure>
    ) async -> Result<WriteGo, PlatformFailure> {
        await claim(handle)
        if queriesSettability {
            if hung.contains(handle.pid) {
                callLog.append(entry)
                await hungWait()
                return .failure(.notResponding)
            }
            guard let window = windows[handle] else {
                callLog.append(entry)
                return .failure(.noWindow)
            }
            guard window.canMove else {
                callLog.append(entry)
                return .failure(.cannotMove)
            }
        }
        let go = admit()
        guard go == .write else {
            callLog.append("\(entry) \(go)")
            return .success(go)
        }
        callLog.append(entry)
        if hung.contains(handle.pid) {
            await hungWait()
            return .failure(.notResponding)
        }
        guard var window = windows[handle] else { return .failure(.noWindow) }
        let result = apply(&window)
        windows[handle] = window
        return result.map { .write }
    }

    /// Claims the next call index, waits for its gate and runs its hook.
    private func claim(_ handle: WindowHandle) async {
        let index = callCount
        callCount += 1
        if let gate = gates.removeValue(forKey: index) { await hold(gate) }
        if let hook = beforeCall[index], var window = windows[handle] {
            hook(&window)
            windows[handle] = window
        }
    }

    /// A call in flight cannot be cancelled: it takes the app's whole timeout.
    private func hungWait() async {
        await clock.sleepIgnoringCancellation(for: .milliseconds(500))
    }

    /// Holds a call at its gate. The engine's task that made it, if any, is parked meanwhile.
    private func hold(_ gate: Gate) async {
        await gate.hold(parking: {
            guard let parked = EngineActivity.parkCurrentTask() else { return nil }
            return { parked.unpark() }
        })
    }

    private func acquireSlot(_ pid: Int32) async {
        guard busyPids.contains(pid) else {
            busyPids.insert(pid)
            return
        }
        // The session ahead of this one opens the gate when it ends; the test's scope opens it if that never comes.
        // Without a scope nothing would, so the wait is skipped and the test fails instead of hanging.
        guard GateScope.current != nil else {
            Issue.record("Two sessions of one app overlap in a test not marked .gated")
            return
        }
        let turn = Gate()
        waiters[pid, default: []].append(turn)
        await turn.hold()
    }

    private func releaseSlot(_ pid: Int32) {
        if var queue = waiters[pid], !queue.isEmpty {
            queue.removeFirst().open()
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

    func readFrame<T: Sendable>(take: @escaping @Sendable (ScreenRect) -> T) async -> Result<T, PlatformFailure> {
        if usedAfterEnd() { return .failure(.cannotMove) }
        return await platform.read(handle, take: take)
    }

    func setSize(_ size: ScreenSize, admit: @escaping @Sendable () -> WriteGo) async -> Result<WriteGo, PlatformFailure> {
        if usedAfterEnd() { return .failure(.cannotMove) }
        return await platform.writeSize(handle, size, admit: admit)
    }

    func setPosition(
        _ point: ScreenPoint,
        admit: @escaping @Sendable () -> WriteGo
    ) async -> Result<WriteGo, PlatformFailure> {
        if usedAfterEnd() { return .failure(.cannotMove) }
        return await platform.writePosition(handle, point, admit: admit)
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
