import Testing
@testable import TaflCore

struct RecognizerTests {
    @Test func recognizesWithinTolerance() {
        let d = display(v)
        #expect(PlacementRecognizer.recognize(rect(0, 25, 500, 775), on: d, gap: 0) == .leftHalf)
        #expect(PlacementRecognizer.recognize(rect(1, 26, 499, 774), on: d, gap: 0) == .leftHalf)
        #expect(PlacementRecognizer.recognize(rect(0, 25, 497, 775), on: d, gap: 0) == nil)
        #expect(PlacementRecognizer.recognize(rect(10, 35, 485, 755), on: d, gap: 10) == .leftHalf)
        #expect(PlacementRecognizer.recognize(rect(1000, 0, 1080, 632), on: display(p), gap: 0) == .firstThird)
    }
}
