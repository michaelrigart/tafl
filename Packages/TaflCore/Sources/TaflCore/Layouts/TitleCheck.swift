public struct TitleCheck: Sendable {
    private struct Pending: Sendable {
        var created: Duration
        var applied: MoveRequest?
    }

    private static let window: Duration = .seconds(1)
    private var pending: [WindowHandle: Pending] = [:]

    public init() {}

    public mutating func created(_ window: WindowHandle, at time: Duration, applied: MoveRequest?) {
        pending[window] = Pending(created: time, applied: applied)
    }

    public mutating func titleChanged(_ window: WindowHandle, at time: Duration, touched: Bool) -> MoveRequest?? {
        guard let entry = pending.removeValue(forKey: window) else { return nil }
        guard !touched, time - entry.created <= Self.window else { return nil }
        return .some(entry.applied)
    }

    public mutating func forget(_ window: WindowHandle) {
        pending[window] = nil
    }
}
