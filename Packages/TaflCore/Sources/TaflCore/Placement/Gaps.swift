import Foundation

/// Port of Rectangle v2.0.4 `GapCalculation.applyGaps`, in top-left coordinates.
public enum Gaps {
    public static func apply(_ gap: Double, to rect: ScreenRect, cell: GridCell) -> ScreenRect {
        let half = gap / 2
        var x = rect.x + gap
        var y = rect.y + gap
        var width = rect.width - 2 * gap
        var height = rect.height - 2 * gap

        if cell.column > 0 {
            x -= half
            width += half
        }
        if cell.column + cell.columnSpan < cell.columns {
            width += half
        }
        if cell.row > 0 {
            y -= half
            height += half
        }
        if cell.row + cell.rowSpan < cell.rows {
            height += half
        }
        return ScreenRect(x: x, y: y, width: width, height: height)
    }
}
