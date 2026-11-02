import Foundation

public enum DisplayTransfer {
    public static func relative(_ frame: ScreenRect, from: Display, to: Display) -> ScreenRect {
        let moved = frame.relative(to: from.visibleFrame).absolute(in: to.visibleFrame)
        return pulledOnScreen(moved, into: to.visibleFrame)
    }

    public static func pulledOnScreen(_ frame: ScreenRect, into visible: ScreenRect) -> ScreenRect {
        let width = min(frame.width, visible.width)
        let height = min(frame.height, visible.height)
        let x = min(max(frame.minX, visible.minX), visible.maxX - width)
        let y = min(max(frame.minY, visible.minY), visible.maxY - height)
        return ScreenRect(x: x, y: y, width: width, height: height)
    }
}
