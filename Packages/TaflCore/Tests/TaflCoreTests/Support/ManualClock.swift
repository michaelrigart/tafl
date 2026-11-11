import Foundation
import Synchronization
import Testing
import TaflTestSupport
@testable import TaflCore

/// A clock that moves only when a test calls `advance(by:)`.
///
/// `advance(by:)` steps time: it moves `now` to each due sleeper's deadline in turn, so a woken
/// task reads its own deadline and a sleep it starts next counts from there. A sleeper that is one
/// of the engine's tasks (`EngineActivity`) stops counting as the engine's work while it sleeps, and
/// counts again before it is woken; `advance` waits for such a task to sleep again or end before it
/// moves on, so a sleep it starts next is due in the same advance when it falls in range. Any other
/// woken task is not waited for. Tests wait on an observable condition (the engine's
/// `quiescent()`, `waitForSleepers` or `task.bounded()`), never on a yield budget.
final class ManualClock: TaflClock {
    private struct Sleeper {
        let id: Int
        let deadline: Duration
        let continuation: CheckedContinuation<Void, any Error>
        /// The engine's task that sleeps, when one does.
        let parked: EngineActivity.Parked?
        /// Whether cancellation cuts the sleep short.
        let cancellable: Bool
        /// Called just before the sleeper is counted again, for a test that gives a task woken too early time to run.
        let beforeUnpark: (@Sendable () -> Void)?

        func wake(with result: Result<Void, any Error>) {
            beforeUnpark?()
            parked?.unpark()
            continuation.resume(with: result)
        }
    }

    private struct State {
        var now: Duration = .zero
        var nextID = 0
        var sleepers: [Sleeper] = []
        var beforeUnpark: (@Sendable () -> Void)?
    }

    private let state = Mutex(State())
    /// Whether the test's `GateScope` lets go the sleeps that ignore cancellation when it opens.
    private let scoped: Bool

    init() {
        let scope = GateScope.current
        scoped = scope != nil
        scope?.onOpen { [self] in releaseUncancellableSleepers() }
    }

    var now: Duration { state.withLock { $0.now } }

    /// How many tasks are suspended in `sleep(for:)` or `sleepIgnoringCancellation(for:)`.
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    func sleep(for duration: Duration) async throws {
        let id = nextID()
        try await withTaskCancellationHandler {
            try await park(id: id, for: duration, cancellable: true)
        } onCancel: {
            let cancelled = state.withLock { state -> Sleeper? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return state.sleepers.remove(at: index)
            }
            cancelled?.wake(with: .failure(CancellationError()))
        }
    }

    /// A sleep that cancellation does not cut short, as a call in flight to an app that does not
    /// answer takes its whole timeout.
    func sleepIgnoringCancellation(for duration: Duration) async {
        // Without a scope nothing would end a sleep the test never advances, so it is skipped and the
        // test fails instead of hanging.
        guard scoped else {
            Issue.record("A sleep that ignores cancellation needs a test marked .gated, which lets it go when the test ends")
            return
        }
        try? await park(id: nextID(), for: duration, cancellable: false)
    }

    /// Moves time forward to `now + duration`, waking sleepers in deadline order. For each one
    /// `now` is set to its deadline first; when time remains and the sleeper is one of the engine's
    /// tasks, `advance` waits for that task to sleep again or end, and a sleep it starts that falls in
    /// range is due in turn.
    func advance(by duration: Duration, sourceLocation: SourceLocation = #_sourceLocation) async {
        let target = state.withLock { $0.now + duration }
        while let sleeper = takeNextSleeper(due: target) {
            sleeper.wake(with: .success(()))
            guard sleeper.deadline < target, let parked = sleeper.parked else { continue }
            await waitUntil("the engine's task woken at \(sleeper.deadline) to sleep again or end", sourceLocation: sourceLocation) {
                !parked.isRunning
            }
        }
        state.withLock { $0.now = max($0.now, target) }
    }

    /// Waits for `count` tasks to be suspended in a sleep, so a test advances only after the sleeper
    /// it started has registered.
    func waitForSleepers(
        _ count: Int,
        timeout: Duration = defaultWaitBound,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        await waitUntil("\(count) sleeper\(count == 1 ? "" : "s") on the clock", timeout: timeout, sourceLocation: sourceLocation) {
            sleeperCount >= count
        }
    }

    /// Ends every sleep that ignores cancellation, as the test's scope opens its gates: nothing else
    /// would end one for a test that never advances the clock far enough.
    private func releaseUncancellableSleepers() {
        let stuck = state.withLock { state -> [Sleeper] in
            let stuck = state.sleepers.filter { !$0.cancellable }
            state.sleepers.removeAll { !$0.cancellable }
            return stuck
        }
        for sleeper in stuck { sleeper.wake(with: .success(())) }
    }

    /// Runs `hook` in the waker just before it counts a woken engine task again; for sleeps begun after this.
    func beforeUnparking(_ hook: @escaping @Sendable () -> Void) {
        state.withLock { $0.beforeUnpark = hook }
    }

    private func nextID() -> Int {
        state.withLock { state in
            defer { state.nextID += 1 }
            return state.nextID
        }
    }

    private func park(id: Int, for duration: Duration, cancellable: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in // lint-tests: allow continuation: the fake clock's sleep, which only advance(by:) or cancellation ends
            let outcome: Result<Void, any Error>? = state.withLock { state in
                if cancellable, Task.isCancelled { return .failure(CancellationError()) }
                let deadline = state.now + duration
                if deadline <= state.now { return .success(()) }
                let parked = EngineActivity.parkCurrentTask()
                state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation, parked: parked, cancellable: cancellable, beforeUnpark: state.beforeUnpark))
                return nil
            }
            if let outcome { continuation.resume(with: outcome) }
        }
    }

    private func takeNextSleeper(due target: Duration) -> Sleeper? {
        state.withLock { state in
            let next = state.sleepers.indices
                .filter { state.sleepers[$0].deadline <= target }
                .min { (state.sleepers[$0].deadline, state.sleepers[$0].id) < (state.sleepers[$1].deadline, state.sleepers[$1].id) }
            guard let next else { return nil }
            let sleeper = state.sleepers.remove(at: next)
            state.now = max(state.now, sleeper.deadline)
            return sleeper
        }
    }
}
