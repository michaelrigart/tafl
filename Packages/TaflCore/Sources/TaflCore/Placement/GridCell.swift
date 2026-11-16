import Foundation

public struct GridCell: Hashable, Sendable {
    public var columns: Int
    public var rows: Int
    public var column: Int
    public var row: Int
    public var columnSpan: Int
    public var rowSpan: Int

    public init(columns: Int, rows: Int, column: Int, row: Int, columnSpan: Int, rowSpan: Int) {
        self.columns = columns
        self.rows = rows
        self.column = column
        self.row = row
        self.columnSpan = columnSpan
        self.rowSpan = rowSpan
    }

    /// Edges are rounded to whole points, so neighbouring cells share them exactly.
    public func rect(in visible: ScreenRect) -> ScreenRect {
        let left = Self.edge(column, of: columns, origin: visible.minX, length: visible.width)
        let right = Self.edge(column + columnSpan, of: columns, origin: visible.minX, length: visible.width)
        let top = Self.edge(row, of: rows, origin: visible.minY, length: visible.height)
        let bottom = Self.edge(row + rowSpan, of: rows, origin: visible.minY, length: visible.height)
        return ScreenRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    private static func edge(_ index: Int, of count: Int, origin: Double, length: Double) -> Double {
        origin + (Double(index) * length / Double(count)).rounded()
    }

    var transposed: GridCell {
        GridCell(
            columns: rows, rows: columns, column: row, row: column,
            columnSpan: rowSpan, rowSpan: columnSpan
        )
    }
}
