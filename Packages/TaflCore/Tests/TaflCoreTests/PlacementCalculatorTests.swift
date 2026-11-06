import Testing
@testable import TaflCore

struct PlacementCalculatorTests {
    private let vDisplay = display(v)

    @Test func namedUsesItsCellInTheVisibleFrame() {
        let result = PlacementCalculator.calculate(.named(.rightHalf), window: rect(100, 300, 400, 200), on: vDisplay)
        #expect(result.rect == rect(500, 25, 500, 775))
        #expect(result.cell == NamedPlacement.rightHalf.cell(portrait: false))
    }

    @Test func thirdsRunDownThePortraitDisplay() {
        let portrait = display(rect(0, 0, 800, 1200))
        let result = PlacementCalculator.calculate(.named(.firstThird), window: rect(0, 0, 100, 100), on: portrait)
        #expect(result.rect == rect(0, 0, 800, 400))
    }

    @Test func cellIsItsRect() {
        let cell = GridCell(columns: 3, rows: 1, column: 0, row: 0, columnSpan: 2, rowSpan: 1)
        let result = PlacementCalculator.calculate(.cell(cell), window: rect(0, 0, 10, 10), on: vDisplay)
        #expect(result.rect == rect(0, 25, 667, 775))
        #expect(result.cell == cell)
    }

    @Test func maximizeHeightKeepsTheWindowsColumn() {
        let result = PlacementCalculator.calculate(.maximizeHeight, window: rect(100, 300, 400, 200), on: vDisplay)
        #expect(result.rect == rect(100, 25, 400, 775))
        #expect(result.cell == nil)
    }

    @Test func centerRoundsTheOrigin() {
        let result = PlacementCalculator.calculate(.center, window: rect(0, 0, 400, 300), on: vDisplay)
        #expect(result.rect == rect(300, 263, 400, 300))
    }

    @Test func centerClampsAnOversizedWindowToTheVisibleFrame() {
        let result = PlacementCalculator.calculate(.center, window: rect(0, 0, 1200, 900), on: vDisplay)
        #expect(result.rect == rect(0, 25, 1000, 775))
    }

    @Test func frameIsAsGiven() {
        let result = PlacementCalculator.calculate(.frame(rect(5, 6, 7, 8)), window: rect(0, 0, 1, 1), on: vDisplay)
        #expect(result.rect == rect(5, 6, 7, 8))
    }

    @Test func relativeIsAbsoluteInTheVisibleFrame() {
        let unit = UnitRect(x: 0.1, y: 0.2, width: 0.5, height: 0.5)
        let result = PlacementCalculator.calculate(.relative(unit), window: rect(0, 0, 1, 1), on: vDisplay)
        #expect(result.rect == rect(100, 180, 500, 388))
    }

    @Test func alignmentIsTheCellsOuterEdges() {
        func edges(_ spec: PlacementSpec) -> AlignmentEdges {
            let placed = PlacementCalculator.calculate(spec, window: rect(0, 0, 1, 1), on: vDisplay)
            return PlacementCalculator.alignment(of: spec, placed)
        }
        #expect(edges(.named(.leftHalf)) == [.left, .top, .bottom])
        #expect(edges(.named(.bottomRight)) == [.right, .bottom])
        #expect(edges(.named(.centerThird)) == [.top, .bottom])
        #expect(edges(.named(.maximize)) == [.left, .right, .top, .bottom])
        #expect(edges(.maximizeHeight) == [.top, .bottom])
        #expect(edges(.center) == [])
        #expect(edges(.frame(rect(0, 25, 10, 10))) == [])
    }
}
