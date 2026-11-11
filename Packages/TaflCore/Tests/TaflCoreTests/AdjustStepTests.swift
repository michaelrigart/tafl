import Testing
@testable import TaflCore

struct AdjustStepTests {
    private func context(
        _ spec: PlacementSpec, gap: Double = 0, minSize: ScreenSize? = nil, visible: ScreenRect = v
    ) -> AdjustContext {
        AdjustContext(visible: visible, gap: gap, minSize: minSize, spec: spec)
    }

    private func placement(_ rect: ScreenRect, cell: GridCell? = nil) -> CalculatedPlacement {
        CalculatedPlacement(rect: rect, cell: cell)
    }

    // MARK: GapStep

    @Test func gapOnMaximizeHeightInsetsTopAndBottom() {
        let result = GapStep().adjust(placement(rect(100, 25, 400, 775)), context(.maximizeHeight, gap: 10))
        #expect(result.rect == rect(100, 35, 400, 755))
    }

    @Test func gapOnACellMatchesGapsApply() {
        let cell = NamedPlacement.rightHalf.cell(portrait: false)
        let result = GapStep().adjust(placement(rect(500, 25, 500, 775), cell: cell), context(.named(.rightHalf), gap: 10))
        #expect(result.rect == Gaps.apply(10, to: rect(500, 25, 500, 775), cell: cell))
        #expect(result.rect == rect(505, 35, 485, 755))
    }

    @Test func gapLeavesCenterFrameAndRelativeAlone() {
        for spec in [PlacementSpec.center, .frame(rect(1, 2, 3, 4)), .remembered(rect(1, 2, 3, 4)), .relative(UnitRect(x: 0, y: 0, width: 1, height: 1))] {
            let input = placement(rect(300, 263, 400, 300))
            #expect(GapStep().adjust(input, context(spec, gap: 10)) == input)
        }
    }

    // MARK: MinimumSizeStep

    @Test func growsALeftHalfToItsMinimumKeepingTheLeftEdge() {
        let result = MinimumSizeStep().adjust(
            placement(rect(0, 25, 500, 775)), context(.named(.leftHalf), minSize: ScreenSize(width: 600, height: 400))
        )
        #expect(result.rect == rect(0, 25, 600, 775))
    }

    @Test func growsARightHalfToTheLeft() {
        let result = MinimumSizeStep().adjust(
            placement(rect(500, 25, 500, 775)), context(.named(.rightHalf), minSize: ScreenSize(width: 600, height: 400))
        )
        #expect(result.rect == rect(400, 25, 600, 775))
    }

    @Test func growsABottomHalfUpwards() {
        let result = MinimumSizeStep().adjust(
            placement(rect(0, 413, 1000, 387)), context(.named(.bottomHalf), minSize: ScreenSize(width: 200, height: 500))
        )
        #expect(result.rect == rect(0, 300, 1000, 500))
    }

    @Test func aGapKeepsTheEdgeOffTheVisibleFrameButStillTouching() {
        let result = MinimumSizeStep().adjust(
            placement(rect(505, 35, 485, 755)), context(.named(.rightHalf), gap: 10, minSize: ScreenSize(width: 600, height: 400))
        )
        #expect(result.rect == rect(390, 35, 600, 755))
    }

    @Test func aRectangleInTheMiddleGrowsFromItsTopLeft() {
        let result = MinimumSizeStep().adjust(
            placement(rect(300, 263, 400, 300)), context(.center, minSize: ScreenSize(width: 500, height: 350))
        )
        #expect(result.rect == rect(300, 263, 500, 350))
    }

    @Test func largeEnoughOrUnknownIsUntouched() {
        let input = placement(rect(0, 25, 500, 775))
        #expect(MinimumSizeStep().adjust(input, context(.center, minSize: ScreenSize(width: 100, height: 100))) == input)
        #expect(MinimumSizeStep().adjust(input, context(.center)) == input)
    }

    // MARK: OnScreenStep

    @Test func pullsAnOffScreenRectOntoTheVisibleFrame() {
        let result = OnScreenStep().adjust(placement(rect(900, 700, 300, 200)), context(.frame(rect(0, 0, 1, 1))))
        #expect(result.rect == rect(700, 600, 300, 200))
    }

    @Test func shrinksAnOversizedRectToTheVisibleFrame() {
        let result = OnScreenStep().adjust(placement(rect(0, 0, 1200, 900)), context(.frame(rect(0, 0, 1, 1))))
        #expect(result.rect == rect(0, 25, 1000, 775))
    }

    @Test func aRememberedFrameStaysWhereTheWindowWas() {
        for input in [rect(900, 700, 300, 200), rect(-100, 100, 300, 200), rect(0, 0, 1200, 900)] {
            let result = OnScreenStep().adjust(placement(input), context(.remembered(input)))
            #expect(result.rect == input)
        }
    }

    @Test func aRectInsideStaysPut() {
        let input = placement(rect(100, 100, 300, 200))
        #expect(OnScreenStep().adjust(input, context(.center)) == input)
    }

    @Test func stepsKeepTheCell() {
        let cell = NamedPlacement.leftHalf.cell(portrait: false)
        let input = placement(rect(0, 25, 500, 775), cell: cell)
        let ctx = context(.named(.leftHalf), gap: 10, minSize: ScreenSize(width: 600, height: 400))
        let steps: [any AdjustStep] = [GapStep(), MinimumSizeStep(), OnScreenStep()]
        #expect(steps.reduce(input) { $1.adjust($0, ctx) }.cell == cell)
    }
}
