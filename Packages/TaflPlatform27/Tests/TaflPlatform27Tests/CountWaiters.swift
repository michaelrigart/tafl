import Synchronization

/// A count that only grows, and callers that wait for it to reach a number. A caller resumes when the
/// count gets there; nothing polls and nothing reads a clock. A test that never gets there is stopped
/// by its own time limit.
final class CountWaiters: Sendable {
    private struct State {
        var count = 0
        var waiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    private let state = Mutex(State())

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

    /// Returns once the count has reached `target`, at once if it already has.
    func wait(for target: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let reached = state.withLock { state in
                if state.count >= target { return true }
                state.waiters.append((target, continuation))
                return false
            }
            if reached { continuation.resume() }
        }
    }
}
