import Foundation

public enum DisplayLocator {
    public static func display(containing frame: ScreenRect, in displays: [Display]) -> Display? {
        let overlapping = displays.filter { frame.intersectionArea($0.frame) > 0 }
        if let best = overlapping.max(by: { frame.intersectionArea($0.frame) < frame.intersectionArea($1.frame) }) {
            return best
        }
        return displays.min { frame.distance(toCentreOf: $0.frame) < frame.distance(toCentreOf: $1.frame) }
    }
}
