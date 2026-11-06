import Foundation

/// Pulls the rectangle inside the visible frame.
public struct OnScreenStep: AdjustStep {
    public init() {}

    public func adjust(_ placement: CalculatedPlacement, _ context: AdjustContext) -> CalculatedPlacement {
        var result = placement
        result.rect = DisplayTransfer.pulledOnScreen(placement.rect, into: context.visible)
        return result
    }
}
