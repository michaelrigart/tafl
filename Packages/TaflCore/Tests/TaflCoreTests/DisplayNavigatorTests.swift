import Testing
@testable import TaflCore

func namedDisplay(_ name: String, _ frame: ScreenRect, serial: UInt32 = 1) -> Display {
    Display(
        identity: DisplayIdentity(name: name, vendor: 7789, model: 30648, serial: serial),
        frame: frame,
        visibleFrame: frame
    )
}

struct DisplayNavigatorTests {
    private let all: [Direction] = [.left, .right, .up, .down]

    private func target(_ from: Display, _ direction: Direction, _ displays: [Display]) -> String? {
        DisplayNavigator.target(from: from.identity, direction, in: displays)?.identity.name
    }

    @Test func twoDisplaysAlwaysReachTheOther() {
        let a = namedDisplay("A", rect(0, 0, 1512, 982), serial: 1)
        let b = namedDisplay("B", rect(1512, -300, 3840, 1600), serial: 2)
        for direction in all {
            #expect(target(a, direction, [a, b]) == "B")
            #expect(target(b, direction, [a, b]) == "A")
        }
    }

    @Test func threeInARow() {
        let l = namedDisplay("L", rect(-1920, 0, 1920, 982), serial: 1)
        let m = namedDisplay("M", rect(0, 0, 1512, 982), serial: 2)
        let r = namedDisplay("R", rect(1512, 0, 1920, 982), serial: 3)
        let displays = [m, r, l]
        #expect(target(m, .left, displays) == "L")
        #expect(target(m, .right, displays) == "R")
        #expect(target(m, .up, displays) == "L")
        #expect(target(m, .down, displays) == "R")
    }

    @Test func stackedDisplays() {
        let a = namedDisplay("A", rect(0, 0, 1512, 982), serial: 1)
        let b = namedDisplay("B", rect(0, -1440, 2560, 1440), serial: 2)
        #expect(target(a, .up, [a, b]) == "B")
    }

    @Test func diagonalCountsByCentre() {
        let a = namedDisplay("A", rect(0, 0, 1000, 800), serial: 1)
        let b = namedDisplay("B", rect(1000, -900, 1000, 800), serial: 2)
        #expect(target(a, .right, [a, b]) == "B")
        #expect(target(a, .up, [a, b]) == "B")
    }

    @Test func nearestCentreInThatDirection() {
        let a = namedDisplay("A", rect(-50, -50, 100, 100), serial: 1)
        let b = namedDisplay("B", rect(50, -250, 100, 100), serial: 2)
        let c = namedDisplay("C", rect(-150, -50, 100, 100), serial: 3)
        #expect(target(a, .right, [a, b, c]) == "B")
        #expect(target(a, .left, [a, b, c]) == "C")
        #expect(target(a, .up, [a, b, c]) == "B")
    }

    @Test func singleDisplayHasNoTarget() {
        let a = namedDisplay("A", rect(0, 0, 1512, 982))
        for direction in all {
            #expect(target(a, direction, [a]) == nil)
        }
    }

    @Test func fallbackWrapsAtBothEnds() {
        let l = namedDisplay("L", rect(-1920, 0, 1920, 982), serial: 1)
        let m = namedDisplay("M", rect(0, 0, 1512, 982), serial: 2)
        let r = namedDisplay("R", rect(1512, 0, 1920, 982), serial: 3)
        #expect(DisplayNavigator.fallbackOrder([r, l, m]).map(\.identity.name) == ["L", "M", "R"])
        #expect(target(l, .up, [l, m, r]) == "R")
        #expect(target(r, .down, [l, m, r]) == "L")
    }

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
