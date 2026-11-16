import Testing
@testable import TaflCore

struct DisplayLocatorTests {
    @Test func locatorPicksLargestOverlap() {
        let a = namedDisplay("A", rect(0, 0, 1000, 800), serial: 1)
        let b = namedDisplay("B", rect(1000, 0, 1000, 800), serial: 2)
        #expect(DisplayLocator.display(containing: rect(800, 100, 500, 300), in: [a, b])?.identity.name == "B")
        #expect(DisplayLocator.display(containing: rect(800, 100, 300, 300), in: [a, b])?.identity.name == "A")
    }

    @Test func locatorFallsBackToNearestCentre() {
        let a = namedDisplay("A", rect(0, 0, 1000, 800), serial: 1)
        let b = namedDisplay("B", rect(1000, 0, 1000, 800), serial: 2)
        #expect(DisplayLocator.display(containing: rect(5000, 0, 100, 100), in: [a, b])?.identity.name == "B")
        #expect(DisplayLocator.display(containing: rect(5000, 0, 100, 100), in: []) == nil)
    }
}
