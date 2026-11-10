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
    /// The windows that were written or already in place.
    var placedWindows: Set<WindowHandle> = []
    /// The failure a run reports, so one run shows one overlay: the first failure of the first
    /// app to finish with one.
    var firstFailure: RunFailure?

    mutating func fail(_ window: WindowHandle, _ kind: FailureKind) {
        failed += 1
        if firstFailure == nil { firstFailure = RunFailure(window: window, kind: kind) }
    }

    mutating func add(_ other: RunCount) {
        moved += other.moved
        unchanged += other.unchanged
        failed += other.failed
        placedWindows.formUnion(other.placedWindows)
        if firstFailure == nil { firstFailure = other.firstFailure }
    }
}

struct RunFailure: Sendable {
    var window: WindowHandle
    var kind: FailureKind
}

/// What events said about apps while observation restarted. It is newer than a restart's answer,
/// so it is laid over it: an app learned meanwhile adds what it is missing, and an app that quit
/// meanwhile is gone whatever the answer says. It also holds what was unobservable when the first
/// pending restart was asked for, less the apps whose retries were still pending then, so a failure
/// that events report while the restart waits is not taken for one that was there before, and an app
/// still being retried counts as one that failed in the transient.
struct RestartJournal {
    private let before: [Int32: Set<ObservedEvent>]
    private var learned: [Int32: Set<ObservedEvent>] = [:]
    private var gone: Set<Int32> = []

    init(before: [Int32: Set<ObservedEvent>]) {
        self.before = before
    }

    /// The apps the result finds unobservable that were not before the restart: a failure that may
    /// come only from a transient, such as a wake.
    func newlyUnobservable(in result: [Int32: Set<ObservedEvent>]) -> Set<Int32> {
        Set(result.filter { !$0.value.isEmpty && (before[$0.key]?.isEmpty ?? true) }.keys)
    }

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

/// Ties the core together: it turns shortcuts, layouts, platform events, display changes and
/// config reloads into requests for the pipeline. Every window reading the engine asks for goes to
/// the window owner, which keeps each window's state and memory (`WindowOwner` lists the reads that
/// skip it).
///
/// An engine starts once and stops once; make a new one to start again. The state lives here;
/// the event handling is in `EngineEvents.swift` and the display change handling in
/// `EngineDisplayChanges.swift`.
public actor WindowEngine {
    let platform: any WindowPlatform
    let clock: any TaflClock
    let timing: EngineTiming
    let owner: WindowOwner
    let writer: FrameWriter
    let queue: WindowRequestQueue
    let memory: MemoryKeeper
    let pipeline: Pipeline
    /// Display reconfigurations: one that begins stops every run that started before it.
    let reconfigurations = Generation()
    /// Layout applications, by a shortcut, the menu or a display change: the newest one decides
    /// the active layout, and stops the runs planned before it began. Begun only through
    /// `beginLayoutApplication()`, which tells the owner.
    let layoutApplications = Generation()
    /// Observation restarts: only the newest commits what it learned.
    let restarts = Generation()
    /// Begun by `stopPlacing`, for the work that cannot read the engine's `isStopping` from its
    /// queue: a raise admits each step against it.
    let stops = Generation()
    private let reportSink: AsyncStream<EngineReport>.Continuation

    var config = Config.defaults
    var activeLayout = ActiveLayout()
    var titleCheck = TitleCheck()
    var tracker: SettleTracker
    /// The displays before the change in progress; nil when no change is in progress.
    var changeOrigin: [Display]?
    /// True once the rules have started for the change in progress: the next settle runs them
    /// again even when the setup is back to where it began, since windows may be half way.
    var rulesStarted = false
    /// True from a start on a placeholder with no setup remembered until the first real setup is
    /// recorded: that one is a first setup, with no rule to run. A settled change to no displays is
    /// no such start; it is a setup, and the one after it is compared with it.
    var awaitingFirstSetup = false
    /// Apps whose events macOS would not deliver, and which events those are. The owner records no
    /// last-known frame for an app whose moves or resizes are among them.
    var unobservable: [Int32: Set<ObservedEvent>] = [:] {
        didSet { owner.leaveOut(pids: Set(unobservable.keys.filter(isLeftOutOfRules))) }
    }
    /// The apps already reported, so each is reported once however often it is learned again.
    var reportedUnobservable: Set<Int32> = []
    /// While a restart is pending: what events said since the first pending one was asked for.
    var restartJournal: RestartJournal?
    /// The apps whose retries are scheduled and not over. A newer restart cancels the schedule but
    /// does not count these as unobservable before it, so it retries them again if they still fail.
    var pendingRetries: Set<Int32> = []
    /// The latest restart; the next one waits for it.
    var restartTask: Task<Void, Never>?
    /// The schedule of tries for the apps the latest restart could not observe.
    var observeRetryTask: Task<Void, Never>?
    var eventTask: Task<Void, Never>?
    /// The wait for the quiet period. An input replaces it; the rules run is not part of it.
    var settleTask: Task<Void, Never>?
    var rulesTask: Task<Void, Never>?
    /// Each window's latest frame read after an event: the next waits for it, and so does a title check.
    var frameReads: [WindowHandle: Task<Void, Never>] = [:]
    var background: [Int: Task<Void, Never>] = [:]
    var nextBackgroundID = 0
    /// How many platform events have been dealt with, for tests to wait on.
    var eventsHandled = 0
    /// The engine's work in progress, for tests to wait until there is none (`quiescent`).
    let activity = EngineActivity()
    /// Set once `stopPlacing` begins: no new request starts, and nothing but `stop` saves.
    var isStopping = false

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
        owner = WindowOwner(adjustments: adjustments)
        writer = FrameWriter(platform: platform, clock: clock, owner: owner, reapplyDelay: timing.reapplyDelay)
        queue = WindowRequestQueue()
        memory = MemoryKeeper(owner: owner, store: store)
        pipeline = Pipeline(platform: platform, writer: writer, queue: queue, owner: owner, steps: steps)
        tracker = SettleTracker(quietPeriod: timing.quietPeriod)
        (reports, reportSink) = AsyncStream.makeStream(of: EngineReport.self)
    }

    public var activeLayoutName: String? { activeLayout.name }

    /// The displays as of the last settled change, or the last time the engine read them: the owner
    /// records last-known frames for them.
    var knownDisplays: [Display] { owner.recordingDisplays }

    /// True from the start of a change until its rules have run: no last-known frame is recorded.
    var isFrozen: Bool { owner.isFrozen }

    /// How many running apps Tafl cannot observe fully; an app that quits is no longer counted.
    public var unobservableAppCount: Int { unobservable.values.filter { !$0.isEmpty }.count }

    // MARK: Lifecycle

    /// Loads the memory, starts observing and, when the display setup differs from the one
    /// the memory last saw, runs the display change rules. Call it once.
    public func start(config: Config) async {
        activity.enter()
        defer { activity.leave() }
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
        learn(await platform.startObserving(notices: owner))
        let current = await platform.displays()
        if current.contains(where: \.isPlaceholder) {
            // A placeholder display is no setup (see `settle`): nothing moves, and nothing is recorded or
            // remembered for it. Recording stays frozen on the last real setup, which the next real setup
            // is compared with; with none remembered the next real setup is a first setup.
            owner.freezeLastKnown(on: remembered.lastDisplays)
            changeOrigin = remembered.lastDisplays
            awaitingFirstSetup = remembered.lastSetup == nil
            listen()
        } else if let lastSetup = remembered.lastSetup, lastSetup != DisplaySetup(current) {
            owner.freezeLastKnown(on: remembered.lastDisplays)
            changeOrigin = remembered.lastDisplays
            // From here a reconfiguration freezes and stops the run below.
            listen()
            await applyDisplayChange(from: remembered.lastDisplays, to: current)
        } else {
            // Taken in the step that resumes recording, before any event is handled: a change that
            // begins from here stores its own setup.
            let began = reconfigurations.current
            owner.recordLastKnown(for: current)
            listen()
            // The seed: every window's first reading, recorded for the current setup.
            _ = await platform.visibleWindows(take: owner.take)
            await rememberDisplays(current, since: began)
        }
    }

    /// The memory names windows by process id. Before any rule reads it, the entries of a process
    /// that has gone, or whose id a process launched since the save has taken, are dropped:
    /// losing them beats moving the wrong window.
    private func forgetGoneProcesses() async {
        let saved = await memory.read()
        let gone = saved.goneProcesses(launched: await platform.launchDates(of: saved.windowPids))
        owner.forgetEntries(of: gone)
    }

    /// A layout application still running finishes against the config in force then: a layout the
    /// reload removed does not become active.
    public func update(config: Config) async {
        activity.enter()
        defer { activity.leave() }
        self.config = config
        activeLayout.reconcile(with: config)
        let layout = activeLayout.name
        await memory.update { $0.activeLayout = layout }
    }

    public func save() async {
        activity.enter()
        defer { activity.leave() }
        guard !isStopping else { return }
        await writeMemory()
    }

    private func writeMemory() async {
        if case .failure = await memory.save() { report(.memorySaveFailed) }
    }

    /// The first step of stopping, which does not wait: the engine places nothing more. It refuses
    /// new requests, and stops the ones queued or running, so the owner refuses their writes at
    /// admission; a startup, a rules run, a layout run or a restart that resumes afterwards sends
    /// nothing more, and nothing saves but `stop`. Quit calls it before it waits for startup and a
    /// restart, which a slow app can hold up. Idempotent.
    public func stopPlacing() async {
        activity.enter()
        defer { activity.leave() }
        isStopping = true
        stops.begin()
        eventTask?.cancel()
        settleTask?.cancel()
        rulesTask?.cancel()
        for task in background.values { task.cancel() }
        observeRetryTask?.cancel()
        observeRetryTask = nil
        eventTask = nil
        settleTask = nil
        rulesTask = nil
        background = [:]
        frameReads = [:]
        await queue.halt()
    }

    /// Stops placing, waits until each request has ended its session and recorded what it did,
    /// stops observing and saves the memory. The engine does not start again.
    public func stop() async {
        activity.enter()
        defer { activity.leave() }
        await stopPlacing()
        await queue.stop()
        await platform.stopObserving()
        await writeMemory()
    }

    /// Registers the platform's observers again, as after a wake or a user switch, and learns
    /// which apps cannot be observed now. The event consumer is untouched. Restarts run one at a
    /// time, and only the newest commits: it lays what events said since the first pending one
    /// was asked for over its answer.
    public func restartObserving() async {
        activity.enter()
        defer { activity.leave() }
        let generation = restarts.begin()
        observeRetryTask?.cancel()
        observeRetryTask = nil
        // The baseline is taken before any registration work, which events may report on meanwhile.
        if restartJournal == nil {
            restartJournal = RestartJournal(before: unobservable.filter { !pendingRetries.contains($0.key) })
        }
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
        guard restarts.isCurrent(generation), !isStopping else { return }
        await platform.stopObserving()
        let apps = await platform.startObserving(notices: owner)
        guard restarts.isCurrent(generation), !isStopping, let journal = restartJournal else { return }
        var answer: [Int32: Set<ObservedEvent>] = [:]
        for app in apps { answer[app.pid, default: []].formUnion(app.missing) }
        unobservable = journal.applied(to: answer)
        restartJournal = nil
        for app in apps where unobservable[app.pid] != nil {
            if reportedUnobservable.insert(app.pid).inserted { report(.unobservable(bundleID: app.bundleID)) }
        }
        // An app that was observable before may have failed only because of a transient (a wake).
        scheduleObserveRetries(for: journal.newlyUnobservable(in: unobservable), after: generation)
    }

    // MARK: Retrying unobservable apps

    /// Tries the apps again at each of the timing's delays, measured from the restart, until none is
    /// left. A newer restart, a stop and an app's quit end the tries for the apps they concern.
    private func scheduleObserveRetries(for pids: Set<Int32>, after generation: Int) {
        let delays = timing.observeRetryDelays
        pendingRetries = delays.isEmpty ? [] : pids
        guard !pendingRetries.isEmpty else { return }
        let unit = activity.startingTask()
        observeRetryTask = Task { [clock] in
            await unit.run {
                var pending = pids
                var elapsed = Duration.zero
                for delay in delays {
                    do { try await clock.sleep(for: delay - elapsed) } catch { return }
                    elapsed = delay
                    pending = await self.observeAgain(pending, after: generation)
                    if pending.isEmpty { return }
                }
                self.endRetries(after: generation)
            }
        }
    }

    /// The last try is over: the apps still failing are given up on, unless a newer restart has begun.
    private func endRetries(after generation: Int) {
        if restarts.isCurrent(generation) { pendingRetries = [] }
    }

    /// The apps still unobservable after trying these again. Whatever has happened meanwhile (a newer
    /// restart, a stop, an app's quit) is respected: nothing changes for the apps it concerns.
    private func observeAgain(_ pids: Set<Int32>, after generation: Int) async -> Set<Int32> {
        guard restarts.isCurrent(generation), !isStopping else { return [] }
        let candidates = pids.filter { !(unobservable[$0]?.isEmpty ?? true) }
        guard !candidates.isEmpty else { return [] }
        let still = await platform.observeAgain(pids: candidates)
        guard restarts.isCurrent(generation), !isStopping else { return [] }
        var remaining: Set<Int32> = []
        for pid in candidates where unobservable[pid] != nil {
            if let app = still.first(where: { $0.pid == pid }) {
                unobservable[pid] = app.missing
                remaining.insert(pid)
            } else {
                unobservable[pid] = nil
            }
        }
        pendingRetries = remaining
        return remaining
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
        activity.enter()
        defer { activity.leave() }
        guard !isStopping else { return }
        guard await platform.isAccessibilityGranted() else {
            report(.failure(.permissionMissing, display: nil))
            return
        }
        let focused: WindowSnapshot
        switch await platform.focusedWindow(take: owner.take) {
        case .failure(.notResponding):
            report(.failure(.notResponding(app: "The app"), display: nil))
            return
        case .failure:
            report(.failure(.noWindow, display: nil))
            return
        case .success(let snapshot):
            focused = snapshot
        }
        owner.touch(focused.handle)
        let pointer = await platform.pointerDisplay()
        let config = config
        let outcome = await pipeline.run(focused.handle, config: config, unplaceable: .explained, plan: { resolved in
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
        })
        if case .failed(let kind) = outcome {
            report(.failure(kind, display: await displayIdentity(of: focused, after: kind)))
        }
    }

    /// The display a failed window is on now. An app that did not answer is not asked again.
    private func displayIdentity(of window: WindowSnapshot, after kind: FailureKind) async -> DisplayIdentity? {
        var frame = window.frame
        if case .notResponding = kind {} else if case .success(let current) = await platform.snapshot(of: window.handle, take: owner.take) {
            frame = current.frame
        }
        return DisplayLocator.display(containing: frame, in: await platform.usableDisplays())?.identity
    }

    // MARK: Layouts

    /// A layout run that a reconfiguration stops reports nothing and does not become active. A run
    /// that a newer layout application overtook still reports, but leaves the active layout, and the
    /// window order, to it. The windows it placed come to the front when it ends; a layout applied
    /// on a display change does not (`run` is shared, the raising is not).
    public func applyLayout(named name: String) async {
        activity.enter()
        defer { activity.leave() }
        guard !isStopping else { return }
        guard await platform.isAccessibilityGranted() else {
            report(.failure(.permissionMissing, display: nil))
            return
        }
        guard let definition = config.layouts.first(where: { $0.name == name }) else { return }
        let application = beginLayoutApplication()
        // Taken before anything is read: a reconfiguration that begins during the reads stops the run.
        let since = reconfigurations.current
        let displays = await platform.usableDisplays()
        let windows = await platform.visibleWindows(take: owner.take)
        guard !isStopping, reconfigurations.isCurrent(since) else { return }
        let requests = LayoutPlanner.requests(definition, windows: windows, displays: displays, source: .layout(name))
        for request in requests { owner.touch(request.window) }
        let count = await run(requests, since: since, application: application)
        guard !isStopping, reconfigurations.isCurrent(since) else { return }
        if layoutApplications.isCurrent(application) { await setActiveLayout(name) }
        report(.layoutApplied(name: name, placed: count.moved + count.unchanged, failed: count.failed))
        // One overlay for the run, saying why its first failure failed.
        if let failure = count.firstFailure, let window = windows.first(where: { $0.handle == failure.window }) {
            report(.failure(failure.kind, display: await displayIdentity(of: window, after: failure.kind)))
        }
        await bringToFront(count.placedWindows, of: definition, among: windows, application: application, since: since)
    }

    /// Last, so the overlay does not wait on an app that does not answer. A newer layout application
    /// raises its own windows, and an older run must not cover them: the platform asks `admit` before
    /// each step of the raise, so a run that is overtaken, stopped, or cut off by Tafl stopping raises nothing more.
    private func bringToFront(
        _ placed: Set<WindowHandle>,
        of definition: LayoutDefinition,
        among windows: [WindowSnapshot],
        application: Int,
        since: Int
    ) async {
        guard !isStopping, reconfigurations.isCurrent(since), layoutApplications.isCurrent(application) else { return }
        let order = LayoutPlanner.raiseOrder(definition, windows: windows, among: placed)
        guard !order.isEmpty else { return }
        let reconfigurations = reconfigurations
        let layoutApplications = layoutApplications
        let stops = stops
        let stopped = stops.current
        await platform.raise(order, admit: {
            reconfigurations.isCurrent(since) && layoutApplications.isCurrent(application) && stops.isCurrent(stopped)
        })
    }

    /// In one step of the engine: the count stops the runs planned before it, and the owner stops
    /// the requests they sent from writing.
    func beginLayoutApplication() -> Int {
        let application = layoutApplications.begin()
        owner.layoutApplicationBegan(application)
        return application
    }

    /// A layout the current config lacks neither becomes active nor is saved.
    func setActiveLayout(_ name: String?) async {
        if let name {
            guard activeLayout.activate(name, in: config) else { return }
        } else {
            activeLayout.endForDisplayChange()
        }
        let active = activeLayout.name
        await memory.update { $0.activeLayout = active }
        await save()
    }

    /// Runs the requests of a layout applied, the display-change rules, or a new window's placement
    /// by the active layout: apps side by side, each app's windows in order, so an app that does not
    /// answer holds up only its own windows. A reconfiguration that has begun since `since` stops
    /// the run, and so does a layout application newer than `application` (the run's own, or the
    /// one current when its requests were planned): the run sends no further request, and counts
    /// only what it sent. A request it sent is part of `application`, so the owner admits none of
    /// its writes once a newer one has begun. Each request records its result in the window's owner
    /// as it ends.
    func run(_ requests: [MoveRequest], since: Int, application: Int) async -> RunCount {
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
        let layoutApplications = layoutApplications
        let isOvertaken: @Sendable () -> Bool = { !layoutApplications.isCurrent(application) }
        let total = await withTaskGroup(of: RunCount.self) { group in
            for pid in order {
                let batch = byApp[pid] ?? []
                group.addTask {
                    var count = RunCount()
                    for request in batch {
                        if Task.isCancelled || !reconfigurations.isCurrent(since) || isOvertaken() { break }
                        // The checks inside the plan close the gap before Resolve's reading begins the request.
                        let refused = Mutex(false)
                        let outcome = await pipeline.run(
                            request.window, config: config, layoutApplication: application
                        ) { _ in
                            guard reconfigurations.isCurrent(since), !isOvertaken() else {
                                refused.withLock { $0 = true }
                                return .nothing
                            }
                            return .request(request)
                        }
                        if !reconfigurations.isCurrent(since) || refused.withLock({ $0 }) { break }
                        switch outcome {
                        case .placed:
                            count.moved += 1
                            count.placedWindows.insert(request.window)
                        case .unchanged:
                            count.unchanged += 1
                            count.placedWindows.insert(request.window)
                        case .failed(let kind): count.fail(request.window, kind)
                        // Neither placed nor failed: a window that stopped being placeable is skipped.
                        case .superseded, .skipped: break
                        }
                    }
                    return count
                }
            }
            var total = RunCount()
            for await count in group { total.add(count) }
            return total
        }
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
        let unit = activity.startingTask()
        let task = Task {
            await unit.run {
                await work()
                self.finishTracked(id)
            }
        }
        background[id] = task
        return task
    }

    private func finishTracked(_ id: Int) {
        background[id] = nil
        eventsHandled += 1
    }

    /// For tests: returns once the engine has received `events` platform events in all and none of
    /// its work can go on without new input or a clock advance (`EngineActivity`). Events the
    /// platform has sent are not seen until received, so a test passes how many it sent.
    nonisolated func quiescent(afterEvents events: Int = 0) async {
        await activity.quiet(afterEvents: events)
    }
}
