import Foundation

/// A point in Accessibility's global space: origin top-left, y downward.
public struct ScreenPoint: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct ScreenSize: Hashable, Codable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct ScreenRect: Hashable, Codable, Sendable {
    public var origin: ScreenPoint
    public var size: ScreenSize

    public init(origin: ScreenPoint, size: ScreenSize) {
        self.origin = origin
        self.size = size
    }

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.init(origin: ScreenPoint(x: x, y: y), size: ScreenSize(width: width, height: height))
    }

    public var x: Double { origin.x }
    public var y: Double { origin.y }
    public var width: Double { size.width }
    public var height: Double { size.height }
    public var minX: Double { origin.x }
    public var maxX: Double { origin.x + size.width }
    public var minY: Double { origin.y }
    public var maxY: Double { origin.y + size.height }
    public var midX: Double { origin.x + size.width / 2 }
    public var midY: Double { origin.y + size.height / 2 }

    public func isClose(to other: ScreenRect, within tolerance: Double) -> Bool {
        abs(x - other.x) <= tolerance
            && abs(y - other.y) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }

    public func intersectionArea(_ other: ScreenRect) -> Double {
        let overlapWidth = min(maxX, other.maxX) - max(minX, other.minX)
        let overlapHeight = min(maxY, other.maxY) - max(minY, other.minY)
        guard overlapWidth > 0, overlapHeight > 0 else { return 0 }
        return overlapWidth * overlapHeight
    }

    public func distance(toCentreOf other: ScreenRect) -> Double {
        let dx = midX - other.midX
        let dy = midY - other.midY
        return (dx * dx + dy * dy).squareRoot()
    }

    public func contains(_ point: ScreenPoint) -> Bool {
        point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY
    }
}
