import Foundation
import Synchronization
@testable import TaflCore

/// A clock that moves only when a test calls `advance(by:)`.
final class ManualClock: TaflClock {
    private struct Sleeper {
        let id: Int
        let deadline: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: Duration = .zero
        var nextID = 0
        var sleepers: [Sleeper] = []
    }

    private let state = Mutex(State())

    var now: Duration { state.withLock { $0.now } }

    /// How many tasks are suspended in `sleep(for:)`.
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    func sleep(for duration: Duration) async throws {
        let id = state.withLock { state -> Int in
            defer { state.nextID += 1 }
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let outcome: Result<Void, any Error>? = state.withLock { state in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    let deadline = state.now + duration
                    if deadline <= state.now { return .success(()) }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
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

    /// Moves `now` and resumes, in deadline order, every sleeper whose deadline has passed.
    /// Each resumed task gets to run before the next is resumed, and before this returns.
    func advance(by duration: Duration) async {
        let due = state.withLock { state -> [Sleeper] in
            state.now += duration
            let due = state.sleepers.filter { $0.deadline <= state.now }
            state.sleepers.removeAll { $0.deadline <= state.now }
            return due.sorted { ($0.deadline, $0.id) < ($1.deadline, $1.id) }
        }
        for sleeper in due {
            sleeper.continuation.resume()
            await settle()
        }
        await settle()
    }

    /// Yields until `count` tasks are suspended in `sleep(for:)`, so a test advances only
    /// after the sleeper it started has registered.
    func waitForSleepers(_ count: Int) async {
        for _ in 0..<100_000 where sleeperCount < count {
            await Task.yield()
        }
    }

    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }
}
