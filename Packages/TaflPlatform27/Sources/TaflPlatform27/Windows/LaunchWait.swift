import AppKit
import Synchronization

/// Waits for an app to finish launching, by key-value observing `isFinishedLaunching`: macOS can announce
/// a launch before the app answers Accessibility. No timer is involved; an app that terminates first ends the wait.
enum LaunchWait {
    static func isLaunching(pid: Int32) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return !app.isFinishedLaunching && !app.isTerminated
    }

    static func untilFinished(pid: Int32) async {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = Once(continuation)
            once.hold(app.observe(\.isFinishedLaunching) { app, _ in if app.isFinishedLaunching { once.resume() } })
            once.hold(app.observe(\.isTerminated) { app, _ in if app.isTerminated { once.resume() } })
            if app.isFinishedLaunching || app.isTerminated { once.resume() }
        }
    }

    private final class Once: Sendable {
        private struct State {
            var continuation: CheckedContinuation<Void, Never>?
            var observations: [NSKeyValueObservation] = []
            var isDone = false
        }

        private let state: Mutex<State>

        init(_ continuation: CheckedContinuation<Void, Never>) {
            state = Mutex(State(continuation: continuation))
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
