import Foundation

public enum DisplayTransfer {
    /// `frame` mapped by its share of `source` onto the same share of `target`, with no pull onto the
    /// screen. A `source` with no width or height has no share to map by: `frame` stays as it is.
    public static func mapped(_ frame: ScreenRect, from source: ScreenRect, to target: ScreenRect) -> ScreenRect {
        guard source.width > 0, source.height > 0 else { return frame }
        return frame.relative(to: source).absolute(in: target)
    }

    /// `frame`, recorded on a display whose frame and visible frame were `recordedDisplay` (nil in a
    /// record from before Tafl kept it) and `recordedVisible`, as it goes on `display` now. Exact while
    /// the display itself is unchanged, whatever its reserved space (the Dock, the menu bar) did;
    /// translated by the display's move when it only moved; mapped onto it when its size changed.
    /// Nothing here pulls the frame onto the screen: `keptOnScreen` is the only pull.
    public static func carried(
        _ frame: ScreenRect,
        recordedDisplay: ScreenRect?,
        recordedVisible: ScreenRect,
        to display: Display
    ) -> ScreenRect {
        if let recordedDisplay {
            if display.frame == recordedDisplay { return frame }
            if display.frame.size == recordedDisplay.size {
                return ScreenRect(
                    origin: ScreenPoint(
                        x: frame.x + display.frame.x - recordedDisplay.x,
                        y: frame.y + display.frame.y - recordedDisplay.y
                    ),
                    size: frame.size
                )
            }
        } else if display.visibleFrame == recordedVisible {
            return frame
        }
        return mapped(frame, from: recordedVisible, to: display.visibleFrame)
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
