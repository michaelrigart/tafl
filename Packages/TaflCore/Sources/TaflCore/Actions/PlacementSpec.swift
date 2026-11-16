import Foundation

public enum PlacementSpec: Equatable, Sendable {
    case named(NamedPlacement)
    case cell(GridCell)
    case maximizeHeight
    case center
    /// A frame to move to, kept on the screen like any other placement (larger and smaller).
    case frame(ScreenRect)
    /// A frame the window already had (restore, a remembered setup): placed exactly, even partly
    /// off-screen.
    case remembered(ScreenRect)
    case relative(UnitRect)
}
