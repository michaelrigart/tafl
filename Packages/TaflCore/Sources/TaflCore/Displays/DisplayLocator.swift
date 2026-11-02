import Foundation

public enum DisplayLocator {
    public static func display(containing frame: ScreenRect, in displays: [Display]) -> Display? {
        let overlapping = displays.filter { frame.intersectionArea($0.frame) > 0 }
        if let best = overlapping.max(by: { frame.intersectionArea($0.frame) < frame.intersectionArea($1.frame) }) {
            return best
        }
        return displays.min { distance(frame, $0.frame) < distance(frame, $1.frame) }
    }

    private static func distance(_ a: ScreenRect, _ b: ScreenRect) -> Double {
        let dx = a.midX - b.midX
        let dy = a.midY - b.midY
        return (dx * dx + dy * dy).squareRoot()
    }
}
