import Foundation

public struct CalculatedPlacement: Equatable, Sendable {
    public var rect: ScreenRect
    /// The grid cell the rectangle came from, for placements that are one.
    public var cell: GridCell?

    public init(rect: ScreenRect, cell: GridCell?) {
        self.rect = rect
        self.cell = cell
    }
}

extension PlacementSpec {
    /// Whether the configured gap applies to this placement.
    var appliesGap: Bool {
        switch self {
        case .named, .cell, .maximizeHeight: true
        case .center, .frame, .relative: false
        }
    }
}

public enum PlacementCalculator {
    public static func calculate(_ spec: PlacementSpec, window: ScreenRect, on display: Display) -> CalculatedPlacement {
        let visible = display.visibleFrame
        switch spec {
        case .named(let placement):
            let cell = placement.cell(portrait: display.isPortrait)
            return CalculatedPlacement(rect: cell.rect(in: visible), cell: cell)
        case .cell(let cell):
            return CalculatedPlacement(rect: cell.rect(in: visible), cell: cell)
        case .maximizeHeight:
            return CalculatedPlacement(
                rect: ScreenRect(x: window.x, y: visible.minY, width: window.width, height: visible.height),
                cell: nil
            )
        case .center:
            let width = min(window.width, visible.width)
            let height = min(window.height, visible.height)
            return CalculatedPlacement(
                rect: ScreenRect(
                    x: (visible.minX + (visible.width - width) / 2).rounded(),
                    y: (visible.minY + (visible.height - height) / 2).rounded(),
                    width: width,
                    height: height
                ),
                cell: nil
            )
        case .frame(let rect):
            return CalculatedPlacement(rect: rect, cell: nil)
        case .relative(let unit):
            return CalculatedPlacement(rect: unit.absolute(in: visible), cell: nil)
        }
    }

    /// The edges of the placement, before gaps, that a window kept at its own size is aligned
    /// to; empty derives them from the target.
    static func alignment(of spec: PlacementSpec, _ placement: CalculatedPlacement) -> AlignmentEdges {
        switch spec {
        case .maximizeHeight:
            return [.top, .bottom]
        case .named, .cell:
            guard let cell = placement.cell else { return [] }
            var edges: AlignmentEdges = []
            if cell.column == 0 { edges.insert(.left) }
            if cell.column + cell.columnSpan == cell.columns { edges.insert(.right) }
            if cell.row == 0 { edges.insert(.top) }
            if cell.row + cell.rowSpan == cell.rows { edges.insert(.bottom) }
            return edges
        case .center, .frame, .relative:
            return []
        }
    }
}
