import Foundation

public enum NamedPlacement: String, CaseIterable, Codable, Sendable {
    case leftHalf = "left-half"
    case rightHalf = "right-half"
    case topHalf = "top-half"
    case bottomHalf = "bottom-half"
    case topLeft = "top-left"
    case topRight = "top-right"
    case bottomLeft = "bottom-left"
    case bottomRight = "bottom-right"
    case firstThird = "first-third"
    case centerThird = "center-third"
    case lastThird = "last-third"
    case firstTwoThirds = "first-two-thirds"
    case centerTwoThirds = "center-two-thirds"
    case lastTwoThirds = "last-two-thirds"
    case maximize

    /// On a portrait display, thirds and two-thirds run down the rows instead of across the columns.
    public func cell(portrait: Bool) -> GridCell {
        switch self {
        case .leftHalf: GridCell(columns: 2, rows: 1, column: 0, row: 0, columnSpan: 1, rowSpan: 1)
        case .rightHalf: GridCell(columns: 2, rows: 1, column: 1, row: 0, columnSpan: 1, rowSpan: 1)
        case .topHalf: GridCell(columns: 1, rows: 2, column: 0, row: 0, columnSpan: 1, rowSpan: 1)
        case .bottomHalf: GridCell(columns: 1, rows: 2, column: 0, row: 1, columnSpan: 1, rowSpan: 1)
        case .topLeft: GridCell(columns: 2, rows: 2, column: 0, row: 0, columnSpan: 1, rowSpan: 1)
        case .topRight: GridCell(columns: 2, rows: 2, column: 1, row: 0, columnSpan: 1, rowSpan: 1)
        case .bottomLeft: GridCell(columns: 2, rows: 2, column: 0, row: 1, columnSpan: 1, rowSpan: 1)
        case .bottomRight: GridCell(columns: 2, rows: 2, column: 1, row: 1, columnSpan: 1, rowSpan: 1)
        case .maximize: GridCell(columns: 1, rows: 1, column: 0, row: 0, columnSpan: 1, rowSpan: 1)
        case .firstThird: oriented(GridCell(columns: 3, rows: 1, column: 0, row: 0, columnSpan: 1, rowSpan: 1), portrait)
        case .centerThird: oriented(GridCell(columns: 3, rows: 1, column: 1, row: 0, columnSpan: 1, rowSpan: 1), portrait)
        case .lastThird: oriented(GridCell(columns: 3, rows: 1, column: 2, row: 0, columnSpan: 1, rowSpan: 1), portrait)
        case .firstTwoThirds: oriented(GridCell(columns: 3, rows: 1, column: 0, row: 0, columnSpan: 2, rowSpan: 1), portrait)
        case .centerTwoThirds: oriented(GridCell(columns: 6, rows: 1, column: 1, row: 0, columnSpan: 4, rowSpan: 1), portrait)
        case .lastTwoThirds: oriented(GridCell(columns: 3, rows: 1, column: 1, row: 0, columnSpan: 2, rowSpan: 1), portrait)
        }
    }

    private func oriented(_ cell: GridCell, _ portrait: Bool) -> GridCell {
        portrait ? cell.transposed : cell
    }
}
