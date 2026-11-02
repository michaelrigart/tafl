import Foundation

public struct SettleTracker: Sendable {
    public static let maximumQuietPeriod = Duration.seconds(3)

    public let quietPeriod: Duration
    public private(set) var isChanging = false
    /// When the reconfiguration still open began: the first `began` while none was open. Window
    /// moves and further `began`s leave it where it is.
    public private(set) var openedAt: Duration?
    private var lastInput: Duration = .zero

    public init(quietPeriod: Duration) {
        precondition(quietPeriod <= Self.maximumQuietPeriod, "The quiet period is capped at 3 s")
        self.quietPeriod = quietPeriod
    }

    public mutating func began(at time: Duration) {
        isChanging = true
        if openedAt == nil { openedAt = time }
        record(time)
    }

    public mutating func ended(at time: Duration) {
        openedAt = nil
        record(time)
    }

    public mutating func windowMoved(at time: Duration) {
        guard isChanging else { return }
        record(time)
    }

    public var deadline: Duration? {
        guard isChanging, openedAt == nil else { return nil }
        return lastInput + quietPeriod
    }

    public mutating func settleIfDue(now: Duration) -> Bool {
        guard let deadline, now >= deadline else { return false }
        isChanging = false
        return true
    }

    private mutating func record(_ time: Duration) {
        lastInput = max(lastInput, time)
    }
}
