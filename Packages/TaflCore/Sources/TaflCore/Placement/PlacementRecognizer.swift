import Foundation

public enum PlacementRecognizer {
    public static let tolerance = 2.0

    public static func recognize(_ frame: ScreenRect, on display: Display, gap: Double) -> NamedPlacement? {
        NamedPlacement.allCases.first { placement in
            let cell = placement.cell(portrait: display.isPortrait)
            let target = Gaps.apply(gap, to: cell.rect(in: display.visibleFrame), cell: cell)
            return frame.isClose(to: target, within: tolerance)
        }
    }
}
