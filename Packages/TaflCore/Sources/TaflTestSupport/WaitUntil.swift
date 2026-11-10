import Testing

/// How long a wait in a test may take before it fails. A condition that holds takes microseconds;
/// the bound only decides how soon a test that cannot reach its condition fails, well inside the
/// tests' one-minute time limits.
public let defaultWaitBound: Duration = .seconds(5)

/// Waits until `holds` is true, checking it after each yield, for at most `timeout` of wall-clock
/// time. When the bound passes, or the caller is cancelled first, it records an issue naming
/// `condition`, opens every gate of the test (`GateScope`) so no later step stays held, and
/// returns false. Tests wait on an observable condition this way, never on a yield count or a sleep.
@discardableResult
public func waitUntil(
    _ condition: String,
    timeout: Duration = defaultWaitBound,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ holds: () async -> Bool
) async -> Bool {
    switch await reach(timeout: timeout, holds) {
    case .held:
        return true
    case .boundPassed:
        waitFailed("Waited \(timeout) for \(condition)", sourceLocation: sourceLocation)
    case .cancelled:
        waitFailed("Cancelled while waiting for \(condition)", sourceLocation: sourceLocation)
    }
    return false
}

enum Reached {
    case held, boundPassed, cancelled
}

/// Checks `holds` until it is true, the bound passes or the caller is cancelled. It yields between
/// checks at first, then sleeps a millisecond, so a long wait does not take a core from the tests
/// running beside it.
func reach(timeout: Duration, _ holds: () async -> Bool) async -> Reached {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    var checks = 0
    while await !holds() {
        if Task.isCancelled { return .cancelled }
        if clock.now >= deadline { return .boundPassed }
        checks += 1
        if checks < 1000 {
            await Task.yield()
        } else {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
    return .held
}

/// A wait that failed: the issue says what it waited for, and every gate of the test opens, so a
/// step held behind one cannot keep the test from ending.
func waitFailed(_ comment: String, sourceLocation: SourceLocation) {
    Issue.record(Comment(rawValue: comment), sourceLocation: sourceLocation)
    GateScope.current?.openAll()
}
