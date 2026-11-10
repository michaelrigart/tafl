import Synchronization
import Testing

/// A count that only grows, and callers that wait for it to reach a number. A caller resumes when the
/// count gets there; nothing polls and nothing reads a clock. A wait that is cancelled before the
/// count gets there (a test's time limit cancels cooperatively) resumes at once and records an issue,
/// so a missing notice fails the test instead of hanging the run.
final class CountWaiters: Sendable {
    private struct Waiter {
        let id: Int
        let target: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var count = 0
        var nextID = 0
        var waiters: [Waiter] = []
    }

    private let state = Mutex(State())

    /// How many callers are parked, waiting for the count.
    var waiterCount: Int { state.withLock { $0.waiters.count } }

    /// Counts one more and resumes the callers whose number it reached.
    func increment() {
        let ready = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.count += 1
            let ready = state.waiters.filter { $0.target <= state.count }.map(\.continuation)
            state.waiters.removeAll { $0.target <= state.count }
            return ready
        }
        ready.forEach { $0.resume() }
    }

    /// Returns once the count has reached `target`, at once if it already has. If the caller is
    /// cancelled first, returns and records an issue.
    func wait(for target: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
        let id = state.withLock { state -> Int in
            defer { state.nextID += 1 }
            return state.nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { state in
                    if state.count >= target || Task.isCancelled { return true }
                    state.waiters.append(Waiter(id: id, target: target, continuation: continuation))
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let cancelled = state.withLock { state -> Waiter? in
                guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return state.waiters.remove(at: index)
            }
            cancelled?.continuation.resume()
        }
        let count = state.withLock { $0.count }
        if count < target {
            Issue.record("Wait for a count of \(target) ended by cancellation at \(count)", sourceLocation: sourceLocation)
        }
    }
}
