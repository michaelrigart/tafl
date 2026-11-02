import Testing
@testable import TaflCore

struct DisplayTransferTests {
    @Test func relativeTransfer() {
        let from = display(v)
        let to = display(rect(1000, 0, 2000, 1550))
        #expect(DisplayTransfer.relative(rect(100, 100, 400, 300), from: from, to: to) == rect(1200, 150, 800, 600))
    }

    @Test func pullsOnScreen() {
        #expect(DisplayTransfer.pulledOnScreen(rect(900, 700, 300, 200), into: v) == rect(700, 600, 300, 200))
        #expect(DisplayTransfer.pulledOnScreen(rect(0, 0, 1200, 900), into: v) == rect(0, 25, 1000, 775))
    }

    @Test func framesInsideStayPut() {
        #expect(DisplayTransfer.pulledOnScreen(rect(100, 100, 300, 200), into: v) == rect(100, 100, 300, 200))
    }
}
