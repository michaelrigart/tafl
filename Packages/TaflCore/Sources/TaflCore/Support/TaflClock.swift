import Foundation

public protocol TaflClock: Sendable {
    var now: Duration { get }
    func sleep(for duration: Duration) async throws
}

/// Measures from its creation.
public struct SystemClock: TaflClock {
    private let start = ContinuousClock.now

    public init() {}

    public var now: Duration { start.duration(to: ContinuousClock.now) }

    public func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}
