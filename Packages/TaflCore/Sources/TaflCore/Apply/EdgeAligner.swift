import Foundation

/// The edges of a placement that a window kept at its own size stays against. Top is the
/// smaller y.
public struct AlignmentEdges: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let left = AlignmentEdges(rawValue: 1 << 0)
    public static let right = AlignmentEdges(rawValue: 1 << 1)
    public static let top = AlignmentEdges(rawValue: 1 << 2)
    public static let bottom = AlignmentEdges(rawValue: 1 << 3)

    /// The edges of `frame` that lie on the edges of `bounds`.
    public static func touching(_ frame: ScreenRect, in bounds: ScreenRect) -> AlignmentEdges {
        var edges: AlignmentEdges = []
        if frame.minX == bounds.minX { edges.insert(.left) }
        if frame.maxX == bounds.maxX { edges.insert(.right) }
        if frame.minY == bounds.minY { edges.insert(.top) }
        if frame.maxY == bounds.maxY { edges.insert(.bottom) }
        return edges
    }
}

/// Where a window of `actualSize` goes when the app refused the target's size: against the
/// edges the placement shares with `visible` (those in `edges`, or those `target` touches
/// when `edges` is empty), centred on an axis where it holds both or neither, then kept
/// inside `visible`. Ported from Rectangle's `ClampedWindowAligner`, `EdgeAlignment` and
/// `WindowFrameBounds`.
public enum EdgeAligner {
    /// A size within a point of the target's leaves the axis alone.
    private static let alignmentTolerance = 1.0

    public static func origin(
        for target: ScreenRect,
        actualSize: ScreenSize,
        visible: ScreenRect,
        edges: AlignmentEdges = [],
        gap: Double = 0
    ) -> ScreenPoint {
        // An accepted size leaves nothing to align: the window stays where the target put it, even
        // partly off the visible frame (a restore).
        if abs(actualSize.width - target.width) <= alignmentTolerance,
           abs(actualSize.height - target.height) <= alignmentTolerance { return target.origin }
        // Rectangle leaves an oversized window at the target's origin.
        guard actualSize.width <= visible.width, actualSize.height <= visible.height else { return target.origin }
        let edges = edges.isEmpty ? AlignmentEdges.touching(target, in: visible) : edges

        var x = target.x
        if abs(actualSize.width - target.width) > alignmentTolerance {
            x = alignedOrigin(
                zoneMin: target.minX, zoneLength: target.width, length: actualSize.width,
                atMin: edges.contains(.left), atMax: edges.contains(.right)
            )
        }
        var y = target.y
        if abs(actualSize.height - target.height) > alignmentTolerance {
            y = alignedOrigin(
                zoneMin: target.minY, zoneLength: target.height, length: actualSize.height,
                atMin: edges.contains(.top), atMax: edges.contains(.bottom)
            )
        }

        // Rectangle's `WindowFrameBounds.constrained`: the gap applies on the right and top only.
        if x < visible.minX {
            x = visible.minX
        } else if x + actualSize.width > visible.maxX {
            x = visible.maxX - actualSize.width - gap
        }
        if y + actualSize.height > visible.maxY {
            y = visible.maxY - actualSize.height
        } else if y < visible.minY {
            y = visible.minY + gap
        }
        return ScreenPoint(x: x, y: y)
    }

    private static func alignedOrigin(
        zoneMin: Double, zoneLength: Double, length: Double, atMin: Bool, atMax: Bool
    ) -> Double {
        if atMin, !atMax { return zoneMin }
        if atMax, !atMin { return zoneMin + zoneLength - length }
        return ((zoneLength - length) / 2).rounded() + zoneMin
    }
}
