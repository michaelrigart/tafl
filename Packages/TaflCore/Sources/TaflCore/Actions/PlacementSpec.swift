import Foundation

public enum PlacementSpec: Equatable, Sendable {
    case named(NamedPlacement)
    case cell(GridCell)
    case maximizeHeight
    case center
    case frame(ScreenRect)
    case relative(UnitRect)
}
