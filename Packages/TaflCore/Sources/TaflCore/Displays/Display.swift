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
    /// A display macOS shows while it wakes in the dark, which is no real display (macOS 27.2: no name,
    /// vendor "unkn", model "virt", 1920 x 1080). A setup that holds one is never settled as a
    /// setup. Never stored: a stored display is a real one.
    public var isPlaceholder: Bool

    private enum CodingKeys: String, CodingKey {
        case identity, frame, visibleFrame
    }

    public init(identity: DisplayIdentity, frame: ScreenRect, visibleFrame: ScreenRect, isPlaceholder: Bool = false) {
        self.identity = identity
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.isPlaceholder = isPlaceholder
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identity = try container.decode(DisplayIdentity.self, forKey: .identity)
        frame = try container.decode(ScreenRect.self, forKey: .frame)
        visibleFrame = try container.decode(ScreenRect.self, forKey: .visibleFrame)
        isPlaceholder = false
    }

    public var isPortrait: Bool { visibleFrame.height > visibleFrame.width }
}

public struct DisplaySetup: Hashable, Codable, Sendable {
    public var identities: Set<DisplayIdentity>

    public init(_ displays: [Display]) {
        identities = Set(displays.map(\.identity))
    }
}
