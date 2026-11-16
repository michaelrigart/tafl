import Foundation

/// A rectangle as fractions of a visible frame.
public struct UnitRect: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public func absolute(in visible: ScreenRect) -> ScreenRect {
        ScreenRect(
            x: (visible.minX + x * visible.width).rounded(),
            y: (visible.minY + y * visible.height).rounded(),
            width: (width * visible.width).rounded(),
            height: (height * visible.height).rounded()
        )
    }
}

extension ScreenRect {
    public func relative(to visible: ScreenRect) -> UnitRect {
        UnitRect(
            x: (minX - visible.minX) / visible.width,
            y: (minY - visible.minY) / visible.height,
            width: width / visible.width,
            height: height / visible.height
        )
    }
}
