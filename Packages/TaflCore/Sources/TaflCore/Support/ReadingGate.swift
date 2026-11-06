import Foundation

/// The rule every reading of a window goes through: the newest reading accepted for each key, and a
/// reading older than that is refused, so a result read earlier never overwrites what a newer
/// reading left. One as new is accepted, so a reading can be recorded in several steps. It is kept
/// in memory only, never saved.
struct ReadingGate<Key: Hashable & Sendable>: Sendable {
    private var newest: [Key: ContinuousClock.Instant] = [:]

    /// Whether a reading taken at `readAt` is at least as new as the newest accepted for the key.
    func accepts(_ key: Key, readAt: ContinuousClock.Instant) -> Bool {
        newest[key].map { readAt >= $0 } ?? true
    }

    /// Accepts the reading when it is at least as new as the newest, which it then becomes.
    @discardableResult
    mutating func admit(_ key: Key, readAt: ContinuousClock.Instant) -> Bool {
        guard accepts(key, readAt: readAt) else { return false }
        newest[key] = readAt
        return true
    }

    func newest(_ key: Key) -> ContinuousClock.Instant? {
        newest[key]
    }

    mutating func forget(where matches: (Key) -> Bool) {
        newest = newest.filter { !matches($0.key) }
    }
}
