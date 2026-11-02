import Foundation

public struct DisplayIdentity: Hashable, Codable, Sendable {
    public var name: String
    public var vendor: UInt32
    public var model: UInt32
    public var serial: UInt32

    public init(name: String, vendor: UInt32, model: UInt32, serial: UInt32) {
        self.name = name
        self.vendor = vendor
        self.model = model
        self.serial = serial
    }

    public var identifier: String { "\(vendor)-\(model)-\(serial)" }
}

public struct Display: Equatable, Codable, Sendable {
    public var identity: DisplayIdentity
    public var frame: ScreenRect
    /// Already corrected for the Dock, menu bar and notch.
    public var visibleFrame: ScreenRect

    public init(identity: DisplayIdentity, frame: ScreenRect, visibleFrame: ScreenRect) {
        self.identity = identity
        self.frame = frame
        self.visibleFrame = visibleFrame
    }

    public var isPortrait: Bool { visibleFrame.height > visibleFrame.width }
}

public struct DisplaySetup: Hashable, Codable, Sendable {
    public var identities: Set<DisplayIdentity>

    public init(_ displays: [Display]) {
        identities = Set(displays.map(\.identity))
    }
}
