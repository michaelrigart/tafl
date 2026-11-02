import Foundation

/// Insets cells by the gap, and `maximizeHeight` by the gap above and below.
public struct GapStep: AdjustStep {
    public init() {}

    public func adjust(_ placement: CalculatedPlacement, _ context: AdjustContext) -> CalculatedPlacement {
        var result = placement
        switch context.spec {
        case .named, .cell:
            guard let cell = placement.cell else { return placement }
            result.rect = Gaps.apply(context.gap, to: placement.rect, cell: cell)
        case .maximizeHeight:
            let rect = placement.rect
            result.rect = ScreenRect(
                x: rect.x, y: rect.y + context.gap, width: rect.width, height: rect.height - 2 * context.gap
            )
        case .center, .frame, .relative:
            break
        }
        return result
    }
}
