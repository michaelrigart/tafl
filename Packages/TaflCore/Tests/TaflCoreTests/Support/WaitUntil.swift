import Testing

/// Polls `condition` with `Task.yield()` until it holds or `timeout` of wall-clock time has
/// passed. Returns whether it held. Tests wait on an observable condition, never on a yield count.
func pollUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
    let start = ContinuousClock.now
    while !condition() {
        if start.duration(to: ContinuousClock.now) > timeout { return false }
        await Task.yield()
    }
    return true
}
