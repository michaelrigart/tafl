import Foundation
import TaflCore

public enum PlatformFactory {
    public static func make() -> any WindowPlatform {
        make(osVersion: ProcessInfo.processInfo.operatingSystemVersion)
    }

    static func make(osVersion: OperatingSystemVersion) -> any WindowPlatform {
        osVersion.majorVersion >= 27 ? Platform27() : UnsupportedPlatform()
    }
}
