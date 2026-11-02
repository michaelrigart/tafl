import Foundation

/// Where a window of `actualSize` goes when the app refused the target's size: against the
/// edges of `target` that touch `visible`'s edges, centred on an axis where it touches both
/// or neither, then kept inside `visible`. Ported from Rectangle's `ClampedWindowAligner`,
/// `EdgeAlignment.edgesAndCorners` and `WindowFrameBounds`, with no gap.
public enum EdgeAligner {
    /// A size within a point of the target's leaves the axis alone.
    private static let alignmentTolerance = 1.0

    public static func origin(for target: ScreenRect, actualSize: ScreenSize, visible: ScreenRect) -> ScreenPoint {
        // Rectangle leaves an oversized window at the target's origin.
        guard actualSize.width <= visible.width, actualSize.height <= visible.height else { return target.origin }

        var x = target.x
        if abs(actualSize.width - target.width) > alignmentTolerance {
            x = alignedOrigin(
                zoneMin: target.minX, zoneLength: target.width, length: actualSize.width,
                touchesMin: target.minX == visible.minX, touchesMax: target.maxX == visible.maxX
            )
        }
        var y = target.y
        if abs(actualSize.height - target.height) > alignmentTolerance {
            y = alignedOrigin(
                zoneMin: target.minY, zoneLength: target.height, length: actualSize.height,
                touchesMin: target.minY == visible.minY, touchesMax: target.maxY == visible.maxY
            )
        }

        if x < visible.minX {
            x = visible.minX
        } else if x + actualSize.width > visible.maxX {
            x = visible.maxX - actualSize.width
        }
        if y + actualSize.height > visible.maxY {
            y = visible.maxY - actualSize.height
        } else if y < visible.minY {
            y = visible.minY
        }
        return ScreenPoint(x: x, y: y)
    }

    private static func alignedOrigin(
        zoneMin: Double, zoneLength: Double, length: Double, touchesMin: Bool, touchesMax: Bool
    ) -> Double {
        if touchesMin, !touchesMax { return zoneMin }
        if touchesMax, !touchesMin { return zoneMin + zoneLength - length }
        return ((zoneLength - length) / 2).rounded() + zoneMin
    }
}
