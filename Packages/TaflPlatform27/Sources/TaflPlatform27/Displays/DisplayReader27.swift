import AppKit
import CoreGraphics

public struct RawDisplay27: Sendable, Equatable {
    public var displayID: UInt32
    public var name: String
    public var vendor: UInt32
    public var model: UInt32
    public var serial: UInt32
    public var frame: Coordinates27.AXRect
    public var visibleFrame: Coordinates27.AXRect
    public var safeAreaTop: CGFloat
}

public enum DisplayReader27 {
    @MainActor
    public static func displays() -> [RawDisplay27] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        let primaryHeight = primary.frame.maxY
        return screens.map { screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return RawDisplay27(
                displayID: id,
                name: screen.localizedName,
                vendor: CGDisplayVendorNumber(id),
                model: CGDisplayModelNumber(id),
                serial: CGDisplaySerialNumber(id),
                frame: Coordinates27.toAX(.init(screen.frame), primaryHeight: primaryHeight),
                visibleFrame: Coordinates27.toAX(.init(screen.visibleFrame), primaryHeight: primaryHeight),
                safeAreaTop: screen.safeAreaInsets.top)
        }
    }
}
