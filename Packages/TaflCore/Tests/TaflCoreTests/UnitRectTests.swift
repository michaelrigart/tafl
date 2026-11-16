import Testing
@testable import TaflCore

struct UnitRectTests {
    @Test func unitRectRoundTrip() {
        let unit = rect(100, 100, 400, 300).relative(to: v)
        #expect(unit.absolute(in: rect(1000, 0, 2000, 1550)) == rect(1200, 150, 800, 600))
    }

    @Test func isCloseComparesAllFourComponents() {
        let a = rect(0, 0, 100, 100)
        #expect(a.isClose(to: rect(2, -2, 102, 98), within: 2))
        #expect(!a.isClose(to: rect(0, 0, 100, 103), within: 2))
    }

    @Test func containsAndIntersection() {
        let a = rect(0, 0, 100, 100)
        #expect(a.contains(ScreenPoint(x: 50, y: 50)))
        #expect(!a.contains(ScreenPoint(x: 100, y: 50)))
        #expect(a.intersectionArea(rect(50, 50, 100, 100)) == 2500)
        #expect(a.intersectionArea(rect(100, 0, 10, 10)) == 0)
    }
}
