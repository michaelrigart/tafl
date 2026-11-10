import Foundation

public struct EngineTiming: Sendable {
    /// How long a display change stays quiet before it counts as settled.
    public var quietPeriod: Duration
    /// The wait before a cross-display placement is applied again; nil applies it once.
    public var reapplyDelay: Duration?
    /// How long a reconfiguration may stay open with no further input before it counts as ended,
    /// so a lost "ended" callback cannot freeze last-known recording for good.
    public var reconfigurationTimeout: Duration

    public init(
        quietPeriod: Duration,
        reapplyDelay: Duration?,
        reconfigurationTimeout: Duration = .seconds(10)
    ) {
        self.quietPeriod = quietPeriod
        self.reapplyDelay = reapplyDelay
        self.reconfigurationTimeout = reconfigurationTimeout
    }

    /// Measured on macOS 27.2 (spec, "Measured on macOS 27.2"): macOS's own window moves end within
    /// 0.5 s of a reconfiguration's end, so 1.5 s leaves margin; nothing changed 25 ms after a
    /// write's last read-back, so there is no reapply.
    public static let measured27 = EngineTiming(
        quietPeriod: .milliseconds(1500),
        reapplyDelay: nil
    )
}
