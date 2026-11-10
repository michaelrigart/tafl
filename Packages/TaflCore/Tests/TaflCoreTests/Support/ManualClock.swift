import Foundation
import Synchronization
import Testing
@testable import TaflCore

/// A clock that moves only when a test calls `advance(by:)`.
///
/// `advance(by:)` steps time: it moves `now` to each due sleeper's deadline in turn, so a
/// woken task reads its own deadline and a sleep it starts next counts from there. It does not
/// promise that a woken task has finished its work when it returns. Tests wait on an observable
/// condition (a log entry, `waitForSleepers`, or `task.bounded()`), never on a yield budget.
final class ManualClock: TaflClock {
    private struct Sleeper {
        let id: Int
        /// The task that called `sleep(for:)`.
        let owner: Int
        let deadline: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: Duration = .zero
        var nextID = 0
        var sleepers: [Sleeper] = []
    }

    /// How long a woken task gets, in wall-clock time, to start its next sleep before
    /// `advance(by:)` moves on. A task that is done never does.
    private static let wakeGrace: Duration = .milliseconds(50)

    private let state = Mutex(State())

    var now: Duration { state.withLock { $0.now } }

    /// How many tasks are suspended in `sleep(for:)`.
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    func sleep(for duration: Duration) async throws {
        let id = state.withLock { state -> Int in
            defer { state.nextID += 1 }
            return state.nextID
        }
        let owner = withUnsafeCurrentTask { $0?.hashValue ?? 0 }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let outcome: Result<Void, any Error>? = state.withLock { state in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    let deadline = state.now + duration
                    if deadline <= state.now { return .success(()) }
                    state.sleepers.append(Sleeper(id: id, owner: owner, deadline: deadline, continuation: continuation))
                    return nil
                }
                if let outcome { continuation.resume(with: outcome) }
            }
        } onCancel: {
            let cancelled = state.withLock { state -> Sleeper? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return state.sleepers.remove(at: index)
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward to `now + duration`, waking sleepers in deadline order. For each one
    /// `now` is set to its deadline first; when time remains, the woken task gets a short
    /// wall-clock grace to start its next sleep, which is then due in turn if it falls in range.
    /// Only a sleep by that same task ends the grace, so other tasks' sleeps cannot cut it short.
    func advance(by duration: Duration) async {
        let target = state.withLock { $0.now + duration }
        while let sleeper = takeNextSleeper(due: target) {
            sleeper.continuation.resume()
            guard sleeper.deadline < target else { continue }
            _ = await pollUntil(timeout: Self.wakeGrace) {
                state.withLock { state in state.sleepers.contains { $0.owner == sleeper.owner } }
            }
        }
        state.withLock { $0.now = max($0.now, target) }
    }

    /// Waits for `count` tasks to be suspended in `sleep(for:)`, so a test advances only after
    /// the sleeper it started has registered. Records an issue after `timeout` of wall-clock time.
    func waitForSleepers(
        _ count: Int,
        timeout: Duration = .seconds(2),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let arrived = await pollUntil(timeout: timeout) { sleeperCount >= count }
        if !arrived {
            Issue.record(
                "Timed out waiting for \(count) sleepers; \(sleeperCount) registered",
                sourceLocation: sourceLocation
            )
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
