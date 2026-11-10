import Foundation
import TaflCore

public enum PlatformFactory {
    /// `accessibilityGranted` is the app's one current answer for the Accessibility grant.
    public static func make(accessibilityGranted: @escaping @Sendable () -> Bool) -> any WindowPlatform {
        make(osVersion: ProcessInfo.processInfo.operatingSystemVersion, accessibilityGranted: accessibilityGranted)
    }

    static func make(
        osVersion: OperatingSystemVersion, accessibilityGranted: @escaping @Sendable () -> Bool
    ) -> any WindowPlatform {
        osVersion.majorVersion >= 27 ? Platform27(accessibilityGranted: accessibilityGranted) : UnsupportedPlatform()
    }
}
