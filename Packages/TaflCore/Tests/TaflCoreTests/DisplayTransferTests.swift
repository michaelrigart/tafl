import Testing
@testable import TaflCore

struct DisplayTransferTests {
    @Test func mappedTransfer() {
        #expect(DisplayTransfer.mapped(rect(100, 100, 400, 300), from: v, to: rect(1000, 0, 2000, 1550)) == rect(1200, 150, 800, 600))
    }

    @Test func mappingKeepsAFramePartlyOffScreenWhereItsShareSays() {
        let target = rect(1000, 0, 1000, 775)
        #expect(DisplayTransfer.mapped(rect(900, 700, 300, 200), from: v, to: target) == rect(1900, 675, 300, 200))
    }

    @Test func pullsOnScreen() {
        #expect(DisplayTransfer.pulledOnScreen(rect(900, 700, 300, 200), into: v) == rect(700, 600, 300, 200))
        #expect(DisplayTransfer.pulledOnScreen(rect(0, 0, 1200, 900), into: v) == rect(0, 25, 1000, 775))
    }

    @Test func framesInsideStayPut() {
        #expect(DisplayTransfer.pulledOnScreen(rect(100, 100, 300, 200), into: v) == rect(100, 100, 300, 200))
    }

    @Test func aSourceWithNoWidthOrHeightLeavesTheFrameWhereItIsForKeptOnScreenToJudge() {
        let frame = rect(900, 700, 300, 200)
        #expect(DisplayTransfer.mapped(frame, from: rect(0, 0, 0, 0), to: v) == frame)
        #expect(DisplayTransfer.mapped(frame, from: rect(0, 25, 0, 775), to: v) == frame)
        #expect(DisplayTransfer.mapped(frame, from: rect(0, 25, 1000, 0), to: v) == frame)
        let only = display(v)
        #expect(DisplayTransfer.keptOnScreen(frame, on: only, among: [only]) == rect(700, 600, 300, 200))
    }

    @Test func aFrameSpreadAcrossTwoDisplaysCountsOnBoth() {
        // A sixth of it on each display, with a gap between them: a third on screen in all.
        let left = display(rect(0, 0, 1000, 800))
        var right = display(rect(1400, 0, 1000, 800))
        right.identity.serial = 9
        let frame = rect(900, 100, 600, 100)
        #expect(DisplayTransfer.keptOnScreen(frame, on: left, among: [left, right]) == frame)
    }

    @Test func aFrameWithLessThanAQuarterOnScreenIsPulledOn() {
        let only = display(v)
        #expect(DisplayTransfer.keptOnScreen(rect(950, 100, 400, 300), on: only, among: [only]) == rect(600, 100, 400, 300))
        #expect(DisplayTransfer.keptOnScreen(rect(700, 100, 400, 300), on: only, among: [only]) == rect(700, 100, 400, 300))
    }
}
