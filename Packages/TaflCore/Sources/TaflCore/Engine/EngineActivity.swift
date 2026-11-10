import Synchronization

/// What the engine is doing, kept so a test can wait until it can do nothing more by itself
/// (`WindowEngine.quiescent(afterEvents:)`). Nothing in the app waits on it.
///
/// Work comes in units, each run in a task of its own: a call into the engine, counted from entry
/// to return, and a task the engine starts, counted from the step that creates it. A unit stops
/// counting while its task is parked on input whose waker credits it back before waking it
/// (`parkCurrentTask()`), as the tests' clock and gates do. Anything a unit awaits in another task
/// (a request, a run's apps, a restart) counts as the unit still running, so a quiet engine never
/// has work left that could go on by itself.
final class EngineActivity: Sendable {
    /// A call into the engine or a task it started, counted from its creation until its body returns.
    final class Unit: Sendable {
        private enum Phase {
            case created, running, parked, over
        }

        private struct State {
            var phase = Phase.created
            /// The task that runs the body, once it runs.
            var task: Int?
        }

        fileprivate let activity: EngineActivity
        private let state = Mutex(State())

        fileprivate init(_ activity: EngineActivity) {
            self.activity = activity
            activity.change(by: 1)
        }

        /// Whether the task can go on by itself: created or running, neither parked nor over.
        var isRunning: Bool {
            state.withLock { $0.phase == .created || $0.phase == .running }
        }

        /// Runs `body` as this unit, in the unit's own task; the unit is over when it returns.
        nonisolated(nonsending) func run<T>(_ body: nonisolated(nonsending) () async -> T) async -> T {
            state.withLock { state in
                state.phase = .running
                state.task = currentTaskID()
            }
            defer {
                state.withLock { $0.phase = .over }
                activity.change(by: -1)
            }
            return await EngineActivity.$current.withValue(self, operation: body)
        }

        fileprivate var isCurrentTask: Bool {
            state.withLock { $0.task != nil && $0.task == currentTaskID() }
        }

        fileprivate func parkIfOwnTask() -> Bool {
            let parked = state.withLock { state -> Bool in
                guard state.phase == .running, let task = state.task, task == currentTaskID() else { return false }
                state.phase = .parked
                return true
            }
            if parked { activity.change(by: -1) }
            return parked
        }

        fileprivate func unpark() {
            // Credited before the change, so the count never shows the woken task as stopped.
            activity.change(by: 1)
            state.withLock { $0.phase = .running }
        }
    }

    /// The unit the current task runs inside of. A task the unit's task creates inherits it, but
    /// only the unit's own task can park it.
    @TaskLocal static var current: Unit?

    private struct Waiter {
        let id: Int
        let events: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var running = 0
        var eventsReceived = 0
        var nextWaiterID = 0
        var waiters: [Waiter] = []

        mutating func takeSatisfied() -> [CheckedContinuation<Void, Never>] {
            guard running == 0 else { return [] }
            let ready = waiters.filter { $0.events <= eventsReceived }
            waiters.removeAll { $0.events <= eventsReceived }
            return ready.map(\.continuation)
        }
    }

    private let state = Mutex(State())

    /// A task about to be created, counted from now: its body runs through the unit's `run`.
    func startingTask() -> Unit {
        Unit(self)
    }

    /// Runs a call into the engine as a unit of the calling task, unless that task already runs one
    /// of this engine's units, as when the engine calls itself.
    nonisolated(nonsending) func call<T>(_ body: nonisolated(nonsending) () async -> T) async -> T {
        if let unit = Self.current, unit.activity === self, unit.isCurrentTask { return await body() }
        return await Unit(self).run(body)
    }

    /// Counts an event the engine has received and dealt with; work it started is counted already.
    func receivedEvent() {
        let ready = state.withLock { state in
            state.eventsReceived += 1
            return state.takeSatisfied()
        }
        ready.forEach { $0.resume() }
    }

    /// A unit's own task, parked by a waker that credits it back before it wakes the task.
    struct Parked: Sendable {
        fileprivate let unit: Unit

        /// Counts the task again; the waker calls it before it wakes the task.
        func unpark() {
            unit.unpark()
        }

        /// Once woken: whether the task is still going, neither parked again nor over.
        var isRunning: Bool { unit.isRunning }
    }

    /// Parks the current task's unit, if the current task is the unit's own task, so it stops
    /// counting until the waker calls `unpark()`. Nil when nothing counts the task.
    static func parkCurrentTask() -> Parked? {
        guard let unit = current, unit.parkIfOwnTask() else { return nil }
        return Parked(unit: unit)
    }

    /// How many events the engine has received and dealt with.
    var eventsReceived: Int { state.withLock { $0.eventsReceived } }

    /// How much work is counted now.
    var running: Int { state.withLock { $0.running } }

    /// Returns once no work can go on by itself and `events` events have been received. Returns at
    /// once when the caller is cancelled.
    func quiet(afterEvents events: Int) async {
        let id = state.withLock { state -> Int in
            defer { state.nextWaiterID += 1 }
            return state.nextWaiterID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let now = state.withLock { state -> Bool in
                    if Task.isCancelled || (state.running == 0 && state.eventsReceived >= events) { return true }
                    state.waiters.append(Waiter(id: id, events: events, continuation: continuation))
                    return false
                }
                if now { continuation.resume() }
            }
        } onCancel: {
            let cancelled = state.withLock { state -> Waiter? in
                guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return state.waiters.remove(at: index)
            }
            cancelled?.continuation.resume()
        }
    }

    fileprivate func change(by delta: Int) {
        let ready = state.withLock { state in
            state.running += delta
            return state.takeSatisfied()
        }
        ready.forEach { $0.resume() }
    }
}

/// The current task, told apart from the others alive with it.
private func currentTaskID() -> Int? {
    withUnsafeCurrentTask { $0?.hashValue }
}
