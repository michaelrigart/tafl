import Foundation
import Synchronization

/// Counts the display reconfigurations that have begun. A request planned before one began
/// reads it to learn that it is stale.
final class ReconfigurationCount: Sendable {
    private let value = Mutex(0)

    var current: Int { value.withLock { $0 } }

    func bump() {
        value.withLock { $0 += 1 }
    }
}

/// What a run of requests came to.
struct RunCount: Sendable {
    /// Windows the run wrote.
    var moved = 0
    /// Windows already where the request puts them.
    var unchanged = 0
    var failed = 0
}

/// Ties the core together: it turns shortcuts, layouts, platform events, display changes and
/// config reloads into requests for the pipeline, and keeps the window memory in step.
///
/// The state lives here; the event handling is in `EngineEvents.swift` and the display
/// change handling in `EngineDisplayChanges.swift`.
public actor WindowEngine {
    let platform: any WindowPlatform
    let clock: any TaflClock
    let timing: EngineTiming
    let writer: FrameWriter
    let queue: WindowRequestQueue
    let memory: MemoryKeeper
    let pipeline: Pipeline
    let reconfigurations = ReconfigurationCount()
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
    var unobservablePIDs: Set<Int32> = []
    /// Windows someone else moved since they were created.
    var movedExternally: Set<WindowHandle> = []
    var eventTask: Task<Void, Never>?
    var settleTask: Task<Void, Never>?
    /// The latest frame judgement per window, which the next one and a title check wait for.
    var frameTasks: [WindowHandle: Task<Void, Never>] = [:]
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

    // MARK: Lifecycle

    public func start(config: Config) async {
        self.config = config
        let load = await memory.load()
        report(.memory(load))
        let remembered = await memory.read()
        activeLayout = ActiveLayout(name: remembered.activeLayout)
        activeLayout.reconcile(with: config)
        let layout = activeLayout.name
        await memory.update { $0.activeLayout = layout }

        await platform.startObserving()
        let current = await platform.displays()
        if let lastSetup = remembered.lastSetup, lastSetup != DisplaySetup(current) {
            knownDisplays = remembered.lastDisplays
            changeOrigin = remembered.lastDisplays
            isFrozen = true
            await applyDisplayChange(from: remembered.lastDisplays, to: current)
        } else {
            knownDisplays = current
            await recordLastKnown(await platform.visibleWindows(), displays: current)
            await memory.update { $0.lastDisplays = current }
        }
        // The stream buffers what happened meanwhile.
        listen()
    }

    public func update(config: Config) async {
        self.config = config
        activeLayout.reconcile(with: config)
        let layout = activeLayout.name
        await memory.update { $0.activeLayout = layout }
    }

    public func save() async {
        _ = await memory.save()
    }

    public func stop() async {
        eventTask?.cancel()
        settleTask?.cancel()
        for task in background.values { task.cancel() }
        eventTask = nil
        settleTask = nil
        background = [:]
        frameTasks = [:]
        await platform.stopObserving()
        await save()
    }

    // MARK: Actions

    public func perform(_ action: Action) async {
        guard await platform.isAccessibilityGranted() else {
            report(.failure(.permissionMissing, display: nil))
            return
        }
        let focused: WindowSnapshot
        switch await platform.focusedWindow() {
        case .failure: report(.failure(.noWindow, display: nil)); return
        case .success(let snapshot): focused = snapshot
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
        if case .failed(let kind) = outcome {
            report(.failure(kind, display: await displayIdentity(of: focused, after: kind)))
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

    public func applyLayout(named name: String) async {
        guard let definition = config.layouts.first(where: { $0.name == name }) else { return }
        await setActiveLayout(name)
        let displays = await platform.displays()
        let windows = await platform.visibleWindows()
        let requests = LayoutPlanner.requests(definition, windows: windows, displays: displays, source: .layout(name))
        let count = await run(requests)
        report(.layoutApplied(name: name, placed: count.moved + count.unchanged, failed: count.failed))
    }

    func setActiveLayout(_ name: String?) async {
        if let name { activeLayout.activate(name) } else { activeLayout.endForDisplayChange() }
        await memory.update { $0.activeLayout = name }
    }

    /// Runs the requests: apps side by side, each app's windows in order, so an app that does
    /// not answer holds up only its own windows. A reconfiguration that begins meanwhile stops
    /// the run.
    func run(_ requests: [MoveRequest]) async -> RunCount {
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
        let began = reconfigurations.current
        return await withTaskGroup(of: RunCount.self) { group in
            for pid in order {
                let batch = byApp[pid] ?? []
                group.addTask {
                    var count = RunCount()
                    for request in batch {
                        if Task.isCancelled || reconfigurations.current != began { break }
                        // The check inside the plan closes the gap before the pipeline reads its epoch.
                        let outcome = await pipeline.run(request.window, config: config) { _ in
                            reconfigurations.current == began ? .request(request) : .nothing
                        }
                        if reconfigurations.current != began { break }
                        switch outcome {
                        case .placed: count.moved += 1
                        case .unchanged: count.unchanged += 1
                        case .failed: count.failed += 1
                        case .superseded: break
                        }
                    }
                    return count
                }
            }
            var total = RunCount()
            for await count in group {
                total.moved += count.moved
                total.unchanged += count.unchanged
                total.failed += count.failed
            }
            return total
        }
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
