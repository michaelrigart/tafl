import Foundation

/// Grows a rectangle to the window's minimum size, keeping the edges that touch the visible
/// frame (within the gap, which keeps them off it) and otherwise the top left.
public struct MinimumSizeStep: AdjustStep {
    public init() {}

    public func adjust(_ placement: CalculatedPlacement, _ context: AdjustContext) -> CalculatedPlacement {
        guard let minimum = context.minSize else { return placement }
        let rect = placement.rect
        let width = max(rect.width, minimum.width)
        let height = max(rect.height, minimum.height)
        let reach = context.gap + 0.5
        let visible = context.visible

        var x = rect.x
        let atRight = abs(rect.maxX - visible.maxX) <= reach
        let atLeft = abs(rect.minX - visible.minX) <= reach
        if atRight, !atLeft { x = rect.maxX - width }

        var y = rect.y
        let atBottom = abs(rect.maxY - visible.maxY) <= reach
        let atTop = abs(rect.minY - visible.minY) <= reach
        if atBottom, !atTop { y = rect.maxY - height }

        var result = placement
        result.rect = ScreenRect(x: x, y: y, width: width, height: height)
        return result
    }
}
