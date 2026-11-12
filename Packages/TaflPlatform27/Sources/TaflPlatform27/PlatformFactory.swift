import Foundation
import TaflCore

public enum PlatformFactory {
    /// `accessibilityGranted` is the app's one current answer for the Accessibility grant. The platform
    /// tries an app again after a failed launch at `observeRetryDelays` on `clock`, the delays the
    /// engine's timing gives its restart retries.
    public static func make(
        accessibilityGranted: @escaping @Sendable () -> Bool, clock: any TaflClock, observeRetryDelays: [Duration]
    ) -> any WindowPlatform {
        make(
            osVersion: ProcessInfo.processInfo.operatingSystemVersion, accessibilityGranted: accessibilityGranted,
            clock: clock, observeRetryDelays: observeRetryDelays)
    }

    static func make(
        osVersion: OperatingSystemVersion,
        accessibilityGranted: @escaping @Sendable () -> Bool,
        clock: any TaflClock = SystemClock(),
        observeRetryDelays: [Duration] = []
    ) -> any WindowPlatform {
        osVersion.majorVersion >= 27
            ? Platform27(accessibilityGranted: accessibilityGranted, clock: clock, observeRetryDelays: observeRetryDelays)
            : UnsupportedPlatform()
    }
}
