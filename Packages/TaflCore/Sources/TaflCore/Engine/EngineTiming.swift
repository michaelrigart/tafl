import Foundation

public struct EngineTiming: Sendable {
    /// How long a display change stays quiet before it counts as settled.
    public var quietPeriod: Duration
    /// The wait before a cross-display placement is applied again; nil applies it once.
    public var reapplyDelay: Duration?
    /// How long a reconfiguration may stay open with no further input before it counts as ended,
    /// so a lost "ended" callback cannot freeze last-known recording for good.
    public var reconfigurationTimeout: Duration
    /// When, measured from an observation restart, the apps it could not observe are registered
    /// again: for about 2 s around a wake, Accessibility calls on live apps fail. Empty tries once.
    public var observeRetryDelays: [Duration]

    public init(
        quietPeriod: Duration,
        reapplyDelay: Duration?,
        reconfigurationTimeout: Duration = .seconds(10),
        observeRetryDelays: [Duration] = []
    ) {
        self.quietPeriod = quietPeriod
        self.reapplyDelay = reapplyDelay
        self.reconfigurationTimeout = reconfigurationTimeout
        self.observeRetryDelays = observeRetryDelays
    }

    /// Measured on macOS 27.2 (spec, "Measured on macOS 27.2"): macOS's own window moves end within
    /// 0.5 s of a reconfiguration's end, so 1.5 s leaves margin; nothing changed 25 ms after a
    /// write's last read-back, so there is no reapply. Accessibility calls on live apps fail for
    /// about 2 s around a wake, so an app that failed then is tried again after 3 s and after 10 s.
    public static let measured27 = EngineTiming(
        quietPeriod: .milliseconds(1500),
        reapplyDelay: nil,
        observeRetryDelays: [.seconds(3), .seconds(10)]
    )
}
