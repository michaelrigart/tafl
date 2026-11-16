import AppKit
import CoreGraphics
import TaflCore

public enum Pointer27 {
    public static func display(in displays: [Display]) -> DisplayIdentity? {
        display(at: NSEvent.mouseLocation, primaryHeight: CGDisplayBounds(CGMainDisplayID()).height, in: displays)
    }

    /// `point` is in AppKit space; each display's frame is half-open, so a seam belongs to the display after it.
    static func display(at point: CGPoint, primaryHeight: CGFloat, in displays: [Display]) -> DisplayIdentity? {
        let x = Double(point.x)
        let y = Double(primaryHeight - point.y)
        return displays.first { display in
            let frame = display.frame
            return x >= frame.minX && x < frame.maxX && y >= frame.minY && y < frame.maxY
        }?.identity
    }
}
