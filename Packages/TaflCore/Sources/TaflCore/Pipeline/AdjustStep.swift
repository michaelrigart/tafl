import Foundation

public struct AdjustContext: Sendable {
    /// The target display's visible frame.
    public var visible: ScreenRect
    /// The gap the placement takes; 0 for placements the gap does not apply to.
    public var gap: Double
    public var minSize: ScreenSize?
    public var spec: PlacementSpec

    public init(visible: ScreenRect, gap: Double, minSize: ScreenSize?, spec: PlacementSpec) {
        self.visible = visible
        self.gap = gap
        self.minSize = minSize
        self.spec = spec
    }
}

public protocol AdjustStep: Sendable {
    func adjust(_ placement: CalculatedPlacement, _ context: AdjustContext) -> CalculatedPlacement
}
