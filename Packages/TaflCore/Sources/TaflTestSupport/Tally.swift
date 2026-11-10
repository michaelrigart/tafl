import Synchronization
import Testing

/// A count that only grows, for a test to wait until it reaches a number: calls started, work
/// queued, notices received.
public final class Tally: Sendable {
    private let count = Mutex(0)

    public init() {}

    public var value: Int { count.withLock { $0 } }

    public func increment() {
        count.withLock { $0 += 1 }
    }

    /// Waits until the count has reached `target`; a wait that fails records an issue and opens
    /// the test's gates.
    @discardableResult
    public func wait(
        for target: Int,
        _ what: String = "a count",
        timeout: Duration = defaultWaitBound,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        await waitUntil("\(what) of \(target)", timeout: timeout, sourceLocation: sourceLocation) {
            value >= target
        }
    }
}
