import Foundation

public struct SettleTracker: Sendable {
    public static let maximumQuietPeriod = Duration.seconds(3)

    public let quietPeriod: Duration
    public private(set) var isChanging = false
    private var reconfigurationOpen = false
    private var lastInput: Duration = .zero

    public init(quietPeriod: Duration) {
        precondition(quietPeriod <= Self.maximumQuietPeriod, "The quiet period is capped at 3 s")
        self.quietPeriod = quietPeriod
    }

    public mutating func began(at time: Duration) {
        isChanging = true
        reconfigurationOpen = true
        lastInput = time
    }

    public mutating func ended(at time: Duration) {
        reconfigurationOpen = false
        lastInput = time
    }

    public mutating func windowMoved(at time: Duration) {
        guard isChanging else { return }
        lastInput = time
    }

    public var deadline: Duration? {
        guard isChanging, !reconfigurationOpen else { return nil }
        return lastInput + quietPeriod
    }

    public mutating func settleIfDue(now: Duration) -> Bool {
        guard let deadline, now >= deadline else { return false }
        isChanging = false
        return true
    }
}
