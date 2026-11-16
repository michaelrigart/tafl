import Dispatch
import Testing

/// A hold for work that runs on a thread of its own and cannot await, such as an Accessibility call on
/// its app's serial queue. `hold()` blocks the thread until the test opens the gate; like a `Gate` it
/// belongs to its test's `GateScope`, which opens it when the test ends or a wait fails, and a hold
/// that nothing opens within its bound records an issue and returns, so no path leaves a thread
/// blocked for good.
public final class ThreadGate: Sendable {
    /// Holds one token once the gate is open, which each thread that passes puts back for the next.
    private let semaphore = DispatchSemaphore(value: 0)

    /// A gate made outside a `.gated` test records an issue: nothing would open it when the test ends.
    public init(sourceLocation: SourceLocation = #_sourceLocation) {
        if let scope = GateScope.current {
            scope.onOpen { [self] in open() }
        } else {
            Issue.record("A gate needs a test marked .gated, which opens it when the test ends", sourceLocation: sourceLocation)
        }
    }

    /// Blocks the calling thread until the gate opens; an open gate lets it through at once.
    public func hold(timeout: Duration = defaultWaitBound, sourceLocation: SourceLocation = #_sourceLocation) {
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        if semaphore.wait(timeout: .now() + seconds) == .timedOut {
            waitFailed("Waited \(timeout) for a thread gate to open", sourceLocation: sourceLocation)
            return
        }
        // Let the next held thread through too: opening is for every holder, not one.
        semaphore.signal()
    }

    /// Lets every held thread go, and every later one through.
    public func open() {
        semaphore.signal()
    }
}
