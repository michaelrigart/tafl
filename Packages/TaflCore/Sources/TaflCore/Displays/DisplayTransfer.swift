import Foundation

public enum DisplayTransfer {
    public static func relative(_ frame: ScreenRect, from: Display, to: Display) -> ScreenRect {
        let source = from.visibleFrame
        guard source.width > 0, source.height > 0 else { return pulledOnScreen(frame, into: to.visibleFrame) }
        let moved = frame.relative(to: source).absolute(in: to.visibleFrame)
        return pulledOnScreen(moved, into: to.visibleFrame)
    }

    public static func pulledOnScreen(_ frame: ScreenRect, into visible: ScreenRect) -> ScreenRect {
        let width = min(frame.width, visible.width)
        let height = min(frame.height, visible.height)
        let x = min(max(frame.minX, visible.minX), visible.maxX - width)
        let y = min(max(frame.minY, visible.minY), visible.maxY - height)
        return ScreenRect(x: x, y: y, width: width, height: height)
    }

    /// The share of a frame that must lie on the connected displays for it to stay where it is.
    static let minimumOnScreen = 0.25

    /// `frame`, kept on `display` as a placement is, unless a fair part of it already lies on the
    /// visible frames of the connected displays: a frame partly off-screen stays where it is.
    public static func keptOnScreen(_ frame: ScreenRect, on display: Display, among displays: [Display]) -> ScreenRect {
        let area = frame.width * frame.height
        let onScreen = displays.reduce(0) { $0 + frame.intersectionArea($1.visibleFrame) }
        if area > 0, onScreen >= area * minimumOnScreen { return frame }
        return pulledOnScreen(frame, into: display.visibleFrame)
    }
}
