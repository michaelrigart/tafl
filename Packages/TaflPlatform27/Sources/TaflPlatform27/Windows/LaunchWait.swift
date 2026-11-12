import AppKit
import Synchronization

/// Waits for an app to finish launching, by key-value observing `isFinishedLaunching`: macOS can announce
/// a launch before the app answers Accessibility. No timer is involved; an app that terminates first ends
/// the wait, and so does the waiting task's cancellation, which takes the observations with it.
enum LaunchWait {
    static func isLaunching(pid: Int32) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return !app.isFinishedLaunching && !app.isTerminated
    }

    static func untilFinished(pid: Int32) async {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        await until(app, finished: \.isFinishedLaunching, terminated: \.isTerminated)
    }

    /// Returns once `finished` or `terminated` is true, or the task is cancelled. Either way the
    /// observations are invalidated before it returns.
    static func until<Object: NSObject>(
        _ object: Object, finished: KeyPath<Object, Bool> & Sendable, terminated: KeyPath<Object, Bool> & Sendable
    ) async {
        let once = Once()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                once.park(continuation)
                once.hold(object.observe(finished) { object, _ in if object[keyPath: finished] { once.resume() } })
                once.hold(object.observe(terminated) { object, _ in if object[keyPath: terminated] { once.resume() } })
                if object[keyPath: finished] || object[keyPath: terminated] { once.resume() }
            }
        } onCancel: {
            once.resume()
        }
    }

    private final class Once: Sendable {
        private struct State {
            var continuation: CheckedContinuation<Void, Never>?
            var observations: [NSKeyValueObservation] = []
            var isDone = false
        }

        private let state = Mutex(State())

        /// Holds the waiter; one the wait has already ended is resumed at once.
        func park(_ continuation: CheckedContinuation<Void, Never>) {
            let isDone = state.withLock { state in
                if !state.isDone { state.continuation = continuation }
                return state.isDone
            }
            if isDone { continuation.resume() }
        }

        func hold(_ observation: NSKeyValueObservation) {
            let kept = state.withLock { state in
                if !state.isDone { state.observations.append(observation) }
                return !state.isDone
            }
            if !kept { observation.invalidate() }
        }

        func resume() {
            let (continuation, observations) = state.withLock { state in
                state.isDone = true
                defer { state.continuation = nil; state.observations = [] }
                return (state.continuation, state.observations)
            }
            observations.forEach { $0.invalidate() }
            continuation?.resume()
        }
    }
}
