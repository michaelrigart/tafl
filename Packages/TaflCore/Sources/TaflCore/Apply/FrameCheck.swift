import Foundation

/// A write Tafl has made to a window and not yet read back.
public struct WriteInFlight: Sendable {
    public var part: WritePart
    /// The window's frame when the write began.
    public var before: ScreenRect
    public var targetVisible: ScreenRect
    public var displays: [Display]

    public init(part: WritePart, before: ScreenRect, targetVisible: ScreenRect, displays: [Display]) {
        self.part = part
        self.before = before
        self.targetVisible = targetVisible
        self.displays = displays
    }
}

/// Whether a frame read of a window is one Tafl's own writes leave there.
struct FrameCheck: Sendable {
    static let tolerance = 1.0

    let adjustments: [MacOSAdjustment]

    /// With nothing in flight, the frame must be within a point of `expected`. While a write is in
    /// flight, the part it writes may differ from the frame before it (macOS accepted, clamped or
    /// refused it), and the other part must be within a point of it or explained by a named macOS
    /// adjustment.
    func isOwn(_ read: ScreenRect, expected: ScreenRect, inFlight: WriteInFlight?) -> Bool {
        guard let inFlight else { return read.isClose(to: expected, within: Self.tolerance) }
        let before = inFlight.before
        let otherChanged = switch inFlight.part {
        case .size: Self.differs(read.origin, before.origin)
        case .position: Self.differs(read.size, before.size)
        }
        guard otherChanged else { return true }
        let adjustment = AdjustmentCase(
            written: inFlight.part, before: before, after: read,
            targetVisible: inFlight.targetVisible, displays: inFlight.displays
        )
        return adjustments.contains { $0.explains(adjustment) }
    }

    static func differs(_ a: ScreenPoint, _ b: ScreenPoint) -> Bool {
        abs(a.x - b.x) > tolerance || abs(a.y - b.y) > tolerance
    }

    static func differs(_ a: ScreenSize, _ b: ScreenSize) -> Bool {
        abs(a.width - b.width) > tolerance || abs(a.height - b.height) > tolerance
    }

    static func differs(_ a: ScreenRect, _ b: ScreenRect) -> Bool {
        !a.isClose(to: b, within: tolerance)
    }
}
