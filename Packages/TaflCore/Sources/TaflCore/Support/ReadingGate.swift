import Foundation

/// The newest reading accepted for each window. A reading older than that is refused, so a result
/// read earlier never overwrites what a newer reading left. One as new is accepted, so a reading
/// can be recorded in several steps. It is kept in memory only, never saved.
struct ReadingGate: Sendable {
    private var newest: [WindowHandle: ContinuousClock.Instant] = [:]

    /// Whether a reading taken at `readAt` is at least as new as the newest accepted for the window.
    func accepts(_ window: WindowHandle, readAt: ContinuousClock.Instant) -> Bool {
        newest[window].map { readAt >= $0 } ?? true
    }

    /// Accepts the reading when it is at least as new as the newest, which it then becomes.
    @discardableResult
    mutating func admit(_ window: WindowHandle, readAt: ContinuousClock.Instant) -> Bool {
        guard accepts(window, readAt: readAt) else { return false }
        newest[window] = readAt
        return true
    }

    mutating func forget(_ window: WindowHandle) {
        newest[window] = nil
    }

    mutating func forget(pid: Int32) {
        newest = newest.filter { $0.key.pid != pid }
    }
}
