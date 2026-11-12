import Foundation

public enum WritePart: Sendable {
    case size, position
}

/// Which part to write first, ported from Rectangle's `ImmediateFrameOrder` with
/// `preferSizeFirst = true`.
public enum WriteOrder {
    public static func sizeFirst(from: ScreenRect, to: ScreenRect, bounds: ScreenRect, acrossDisplays: Bool) -> Bool {
        // Moving an off-screen window first can make the system resize it against the Dock.
        if acrossDisplays || !isInside(from, bounds: bounds, slack: 1) { return true }
        let resized = overflow(ScreenRect(origin: from.origin, size: to.size), bounds: bounds)
        let moved = overflow(ScreenRect(origin: to.origin, size: from.size), bounds: bounds)
        if abs(resized - moved) > 1 { return resized < moved }
        return true
    }

    private static func isInside(_ frame: ScreenRect, bounds: ScreenRect, slack: Double) -> Bool {
        frame.minX >= bounds.minX - slack && frame.maxX <= bounds.maxX + slack
            && frame.minY >= bounds.minY - slack && frame.maxY <= bounds.maxY + slack
    }

    private static func overflow(_ frame: ScreenRect, bounds: ScreenRect) -> Double {
        max(0, bounds.minX - frame.minX) + max(0, frame.maxX - bounds.maxX)
            + max(0, bounds.minY - frame.minY) + max(0, frame.maxY - bounds.maxY)
    }
}
