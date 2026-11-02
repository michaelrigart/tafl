import Foundation
import Synchronization

/// Counts the operations of one kind that have begun. Work takes the count when it starts, and is
/// stale once a newer operation of the kind has begun: the newest one wins.
final class Generation: Sendable {
    private let value = Mutex(0)

    var current: Int { value.withLock { $0 } }

    /// Begins a newer operation and returns its generation.
    @discardableResult
    func begin() -> Int {
        value.withLock { value in
            value += 1
            return value
        }
    }

    func isCurrent(_ generation: Int) -> Bool {
        current == generation
    }
}

/// What a run of requests came to.
struct RunCount: Sendable {
    /// Windows the run wrote.
    var moved = 0
    /// Windows already where the request puts them.
    var unchanged = 0
    var failed = 0
    /// The failure a run reports, so one run shows one overlay: the first failure of the first
    /// app to finish with one.
    var firstFailure: RunFailure?
    /// Where the windows the run wrote ended up.
    var placed: [KnownFrame] = []
    /// Windows someone moved while the run placed them.
    var interrupted: [WindowHandle] = []

    mutating func fail(_ window: WindowHandle, _ kind: FailureKind) {
        failed += 1
        if firstFailure == nil { firstFailure = RunFailure(window: window, kind: kind) }
        if kind == .movedDuringPlacement { interrupted.append(window) }
    }

    mutating func add(_ other: RunCount) {
        moved += other.moved
        unchanged += other.unchanged
        failed += other.failed
        if firstFailure == nil { firstFailure = other.firstFailure }
        placed += other.placed
        interrupted += other.interrupted
    }
}

struct RunFailure: Sendable {
    var window: WindowHandle
    var kind: FailureKind
}

struct KnownFrame: Sendable {
    var handle: WindowHandle
    var frame: ScreenRect
}

/// What events said about apps while observation restarted. It is newer than a restart's answer,
/// so it is laid over it: an app learned meanwhile adds what it is missing, and an app that quit
/// meanwhile is gone whatever the answer says.
struct RestartJournal {
    private var learned: [Int32: Set<ObservedEvent>] = [:]
    private var gone: Set<Int32> = []

    mutating func learn(pid: Int32, missing: Set<ObservedEvent>) {
        learned[pid, default: []].formUnion(missing)
        gone.remove(pid)
    }

    mutating func quit(pid: Int32) {
        learned[pid] = nil
        gone.insert(pid)
    }

    func applied(to answer: [Int32: Set<ObservedEvent>]) -> [Int32: Set<ObservedEvent>] {
        var result = answer.filter { !gone.contains($0.key) }
        for (pid, missing) in learned { result[pid, default: []].formUnion(missing) }
        return result
    }
}

/// The latest frame judgement for a window. The token names the window while it lives: a
/// judgement that finds the token gone belongs to a window that was destroyed or whose app quit.
struct FrameWork {
    var token: Int
    var task: Task<Void, Never>
}

/// Ties the core together: it turns shortcuts, layouts, platform events, display changes and
/// config reloads into requests for the pipeline, and keeps the window memory in step.
///
/// An engine starts once and stops once; make a new one to start again. The state lives here;
/// the event handling is in `EngineEvents.swift` and the display change handling in
/// `EngineDisplayChanges.swift`.
public actor WindowEngine {
    let platform: any WindowPlatform
    let clock: any TaflClock
    let timing: EngineTiming
    let writer: FrameWriter
    let queue: WindowRequestQueue
    let memory: MemoryKeeper
    let pipeline: Pipeline
    /// Display reconfigurations: one that begins stops every run that started before it.
    let reconfigurations = Generation()
    /// Layout applications, by a shortcut, the menu or a display change: the newest one decides
    /// the active layout.
    let layoutApplications = Generation()
    /// Observation restarts: only the newest commits what it learned.
    let restarts = Generation()
    private let reportSink: AsyncStream<EngineReport>.Continuation

    var config = Config.defaults
    var activeLayout = ActiveLayout()
    var titleCheck = TitleCheck()
    var tracker: SettleTracker
    /// The displays as of the last settled change, or the last time the engine read them.
    var knownDisplays: [Display] = []
    /// The displays before the change in progress; nil when no change is in progress.
    var changeOrigin: [Display]?
    /// True from the start of a change until its rules have run: no last-known frame is recorded.
    var isFrozen = false
    /// True once the rules have started for the change in progress: the next settle runs them
    /// again even when the setup is back to where it began, since windows may be half way.
    var rulesStarted = false
    /// Apps whose events macOS would not deliver, and which events those are.
    var unobservable: [Int32: Set<ObservedEvent>] = [:]
    /// The apps already reported, so each is reported once however often it is learned again.
    var reportedUnobservable: Set<Int32> = []
    /// The windows of each run in progress that are still alive, so a run records nothing for a
    /// window that was destroyed, or whose app quit, meanwhile.
    var runWindows: [Int: Set<WindowHandle>] = [:]
    var nextRunID = 0
    /// While start seeds last-known frames: the windows an event recorded a frame for since the
    /// seed began reading. The seed leaves those alone, since the event is newer than its read.
    var recordedDuringSeed: Set<WindowHandle>?
    /// While a restart is pending: what events said since the first pending one was asked for.
    var restartJournal: RestartJournal?
    /// The latest restart; the next one waits for it.
    var restartTask: Task<Void, Never>?
    /// Windows someone else moved since they were created.
    var movedExternally: Set<WindowHandle> = []
    var eventTask: Task<Void, Never>?
    /// The wait for the quiet period. An input replaces it; the rules run is not part of it.
    var settleTask: Task<Void, Never>?
    var rulesTask: Task<Void, Never>?
    var frameTasks: [WindowHandle: FrameWork] = [:]
    var nextFrameToken = 0
    var background: [Int: Task<Void, Never>] = [:]
    var nextBackgroundID = 0
    /// How many platform events have been dealt with, for tests to wait on.
    var eventsHandled = 0

    public nonisolated let reports: AsyncStream<EngineReport>

    public init(
        platform: any WindowPlatform,
        store: MemoryStore?,
        clock: any TaflClock,
        timing: EngineTiming,
        steps: [any AdjustStep],
        adjustments: [MacOSAdjustment]
    ) {
        self.platform = platform
        self.clock = clock
        self.timing = timing
        writer = FrameWriter(
            platform: platform, clock: clock, adjustments: adjustments, reapplyDelay: timing.reapplyDelay
        )
        queue = WindowRequestQueue()
        memory = MemoryKeeper(store: store)
        pipeline = Pipeline(platform: platform, writer: writer, queue: queue, memory: memory, steps: steps)
        tracker = SettleTracker(quietPeriod: timing.quietPeriod)
        (reports, reportSink) = AsyncStream.makeStream(of: EngineReport.self)
    }

    public var activeLayoutName: String? { activeLayout.name }

    /// How many running apps Tafl cannot observe fully; an app that quits is no longer counted.
    public var unobservableAppCount: Int { unobservable.values.filter { !$0.isEmpty }.count }

    // MARK: Lifecycle

    /// Loads the memory, starts observing and, when the display setup differs from the one
    /// the memory last saw, runs the display change rules. Call it once.
    public func start(config: Config) async {
        self.config = config
        let load = await memory.load()
        report(.memory(load))
        await forgetGoneProcesses()
        let remembered = await memory.read()
        activeLayout = ActiveLayout(name: remembered.activeLayout)
        activeLayout.reconcile(with: config)
        let layout = activeLayout.name
        await memory.update { $0.activeLayout = layout }

        // Apps that failed to register are known before any rule or seed looks at a window.
        learn(await platform.startObserving())
        let current = await platform.displays()
        if let lastSetup = remembered.lastSetup, lastSetup != DisplaySetup(current) {
            knownDisplays = remembered.lastDisplays
            changeOrigin = remembered.lastDisplays
            isFrozen = true
            // From here a reconfiguration freezes and stops the run below.
            listen()
            await applyDisplayChange(from: remembered.lastDisplays, to: current)
        } else {
            knownDisplays = current
            listen()
            let since = reconfigurations.current
            recordedDuringSeed = []
            let visible = await platform.visibleWindows()
            let newer = recordedDuringSeed ?? []
            recordedDuringSeed = nil
            await recordLastKnown(
                windows: visible.filter { !newer.contains($0.handle) }, displays: current, since: since
            )
            await memory.update { $0.lastDisplays = current }
        }
    }

    /// The memory names windows by process id. Before any rule reads it, the entries of a process
    /// that has gone, or whose id a process launched since the save has taken, are dropped:
    /// losing them beats moving the wrong window.
    private func forgetGoneProcesses() async {
        let saved = await memory.read()
        let gone = saved.goneProcesses(launched: await platform.launchDates(of: saved.windowPids))
        await memory.update { $0.forget(pids: gone) }
    }

    public func update(config: Config) async {
        self.config = config
        activeLayout.reconcile(with: config)
        let layout = activeLayout.name
        await memory.update { $0.activeLayout = layout }
    }

    public func save() async {
        if case .failure = await memory.save() { report(.memorySaveFailed) }
    }

    /// Stops observing and saves the memory. The engine does not start again.
    public func stop() async {
        eventTask?.cancel()
        settleTask?.cancel()
        rulesTask?.cancel()
        for task in background.values { task.cancel() }
        eventTask = nil
        settleTask = nil
        rulesTask = nil
        background = [:]
        frameTasks = [:]
        await platform.stopObserving()
        await save()
    }

    /// Registers the platform's observers again, as after a wake or a user switch, and learns
    /// which apps cannot be observed now. The event consumer is untouched. Restarts run one at a
    /// time, and only the newest commits: it lays what events said since the first pending one
    /// was asked for over its answer.
    public func restartObserving() async {
        let generation = restarts.begin()
        if restartJournal == nil { restartJournal = RestartJournal() }
        let previous = restartTask
        let task = Task {
            await previous?.value
            await self.restart(generation)
        }
        restartTask = task
        await task.value
    }

    private func restart(_ generation: Int) async {
        // A newer restart is waiting and registers the observers itself.
        guard restarts.isCurrent(generation) else { return }
        await platform.stopObserving()
        let apps = await platform.startObserving()
        guard restarts.isCurrent(generation), let journal = restartJournal else { return }
        var answer: [Int32: Set<ObservedEvent>] = [:]
        for app in apps { answer[app.pid, default: []].formUnion(app.missing) }
        unobservable = journal.applied(to: answer)
        restartJournal = nil
        for app in apps where unobservable[app.pid] != nil {
            if reportedUnobservable.insert(app.pid).inserted { report(.unobservable(bundleID: app.bundleID)) }
        }
    }

    // MARK: Unobservable apps

    func learn(_ apps: [UnobservableApp]) {
        for app in apps { learn(pid: app.pid, bundleID: app.bundleID, missing: app.missing) }
    }

    /// An app is reported once; later events for it add to what is known to be missing.
    func learn(pid: Int32, bundleID: String?, missing: Set<ObservedEvent>) {
        unobservable[pid, default: []].formUnion(missing)
        restartJournal?.learn(pid: pid, missing: missing)
        if reportedUnobservable.insert(pid).inserted { report(.unobservable(bundleID: bundleID)) }
    }

    /// Without its moves and resizes Tafl has no last-known frames for an app, and the display
    /// change rules leave it alone.
    func isLeftOutOfRules(pid: Int32) -> Bool {
        guard let missing = unobservable[pid] else { return false }
        return missing.contains(.moved) || missing.contains(.resized)
    }

    /// Without its creations Tafl does not see the app's new windows.
    func isLeftOutOfPlacement(pid: Int32) -> Bool {
        unobservable[pid]?.contains(.created) ?? false
    }

    // MARK: Actions

    public func perform(_ action: Action) async {
        let since = reconfigurations.current
        guard await platform.isAccessibilityGranted() else {
            report(.failure(.permissionMissing, display: nil))
            return
        }
        let focused: WindowSnapshot
        switch await platform.focusedWindow() {
        case .failure(.notResponding):
            report(.failure(.notResponding(app: "The app"), display: nil))
            return
        case .failure:
            report(.failure(.noWindow, display: nil))
            return
        case .success(let snapshot):
            focused = snapshot
        }
        let pointer = await platform.pointerDisplay()
        let config = config
        let outcome = await pipeline.run(focused.handle, config: config) { resolved in
            let context = ActionContext(
                window: resolved.snapshot,
                display: resolved.display,
                displays: resolved.displays,
                pointerDisplay: pointer,
                placed: resolved.placed,
                isAtAchieved: resolved.isAtAchieved,
                restoreTarget: resolved.restoreTarget,
                config: config
            )
            switch ActionResolver.plan(action, context) {
            case .move(let spec, let target, let placement, let cycleStep):
                return .request(MoveRequest(
                    window: focused.handle,
                    spec: spec,
                    display: target.identity,
                    placement: placement,
                    cycleStep: cycleStep,
                    source: .action(action)
                ))
            case .nothing: return .nothing
            case .fail(let kind): return .fail(kind)
            }
        }
        switch outcome {
        case .placed(let frame):
            await recordLastKnownLive([KnownFrame(handle: focused.handle, frame: frame)], since: since)
        case .failed(let kind):
            report(.failure(kind, display: await displayIdentity(of: focused, after: kind)))
        case .unchanged, .superseded:
            break
        }
    }

    /// The display a failed window is on now. An app that did not answer is not asked again.
    private func displayIdentity(of window: WindowSnapshot, after kind: FailureKind) async -> DisplayIdentity? {
        var frame = window.frame
        if case .notResponding = kind {} else if case .success(let current) = await platform.snapshot(of: window.handle) {
            frame = current.frame
        }
        return DisplayLocator.display(containing: frame, in: await platform.displays())?.identity
    }

    // MARK: Layouts

    /// A layout run that a reconfiguration stops reports nothing and does not become active. A run
    /// that a newer layout application overtook still reports, but leaves the active layout to it.
    public func applyLayout(named name: String) async {
        guard let definition = config.layouts.first(where: { $0.name == name }) else { return }
        let application = layoutApplications.begin()
        // Taken before anything is read: a reconfiguration that begins during the reads stops the run.
        let since = reconfigurations.current
        let displays = await platform.displays()
        let windows = await platform.visibleWindows()
        guard reconfigurations.isCurrent(since) else { return }
        let requests = LayoutPlanner.requests(definition, windows: windows, displays: displays, source: .layout(name))
        let count = await run(requests, since: since)
        guard reconfigurations.isCurrent(since) else { return }
        if layoutApplications.isCurrent(application) { await setActiveLayout(name) }
        report(.layoutApplied(name: name, placed: count.moved + count.unchanged, failed: count.failed))
        // One overlay for the run, saying why its first failure failed.
        if let failure = count.firstFailure, let window = windows.first(where: { $0.handle == failure.window }) {
            report(.failure(failure.kind, display: await displayIdentity(of: window, after: failure.kind)))
        }
    }

    func setActiveLayout(_ name: String?) async {
        if let name { activeLayout.activate(name) } else { activeLayout.endForDisplayChange() }
        await memory.update { $0.activeLayout = name }
        await save()
    }

    /// Runs the requests: apps side by side, each app's windows in order, so an app that does
    /// not answer holds up only its own windows. A reconfiguration that has begun since `since`
    /// stops the run. Windows the run wrote are recorded as last known, unless a change is in
    /// progress.
    func run(_ requests: [MoveRequest], since: Int) async -> RunCount {
        var order: [Int32] = []
        var byApp: [Int32: [MoveRequest]] = [:]
        for request in requests {
            let pid = request.window.pid
            if byApp[pid] == nil { order.append(pid) }
            byApp[pid, default: []].append(request)
        }
        let pipeline = pipeline
        let config = config
        let reconfigurations = reconfigurations
        let runID = nextRunID
        nextRunID += 1
        runWindows[runID] = Set(requests.map(\.window))
        let total = await withTaskGroup(of: RunCount.self) { group in
            for pid in order {
                let batch = byApp[pid] ?? []
                group.addTask {
                    var count = RunCount()
                    for request in batch {
                        if Task.isCancelled || !reconfigurations.isCurrent(since) { break }
                        // The check inside the plan closes the gap before the pipeline reads its epoch.
                        let outcome = await pipeline.run(request.window, config: config) { _ in
                            reconfigurations.isCurrent(since) ? .request(request) : .nothing
                        }
                        if !reconfigurations.isCurrent(since) { break }
                        switch outcome {
                        case .placed(let frame):
                            count.moved += 1
                            count.placed.append(KnownFrame(handle: request.window, frame: frame))
                        case .unchanged: count.unchanged += 1
                        case .failed(let kind): count.fail(request.window, kind)
                        case .superseded: break
                        }
                    }
                    return count
                }
            }
            var total = RunCount()
            for await count in group { total.add(count) }
            return total
        }
        // Someone moved the window while it was placed: a title check must not place it again.
        movedExternally.formUnion(total.interrupted)
        let alive = runWindows[runID] ?? []
        runWindows[runID] = nil
        await recordLastKnownLive(total.placed.filter { alive.contains($0.handle) }, since: since)
        return total
    }

    // MARK: Helpers

    func report(_ report: EngineReport) {
        reportSink.yield(report)
    }

    /// Runs `work` beside the event loop, so one slow window does not hold up the events behind
    /// it. It counts as one handled event when it finishes.
    @discardableResult
    func track(_ work: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let id = nextBackgroundID
        nextBackgroundID += 1
        let task = Task {
            await work()
            self.finishTracked(id)
        }
        background[id] = task
        return task
    }

    private func finishTracked(_ id: Int) {
        background[id] = nil
        eventsHandled += 1
    }
}
