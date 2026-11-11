import Foundation

/// Pulls the rectangle inside the visible frame, except a remembered frame, which the window
/// already had.
public struct OnScreenStep: AdjustStep {
    public init() {}

    public func adjust(_ placement: CalculatedPlacement, _ context: AdjustContext) -> CalculatedPlacement {
        if case .remembered = context.spec { return placement }
        var result = placement
        result.rect = DisplayTransfer.pulledOnScreen(placement.rect, into: context.visible)
        return result
    }
}
