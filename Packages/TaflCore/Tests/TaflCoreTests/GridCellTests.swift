import Testing
@testable import TaflCore

struct GridCellTests {
    @Test func halvesAndQuartersOnV() {
        #expect(NamedPlacement.leftHalf.cell(portrait: false).rect(in: v) == rect(0, 25, 500, 775))
        #expect(NamedPlacement.rightHalf.cell(portrait: false).rect(in: v) == rect(500, 25, 500, 775))
        #expect(NamedPlacement.topHalf.cell(portrait: false).rect(in: v) == rect(0, 25, 1000, 388))
        #expect(NamedPlacement.bottomHalf.cell(portrait: false).rect(in: v) == rect(0, 413, 1000, 387))
        #expect(NamedPlacement.topLeft.cell(portrait: false).rect(in: v) == rect(0, 25, 500, 388))
    }

    @Test func thirdsShareEdges() {
        #expect(NamedPlacement.firstThird.cell(portrait: false).rect(in: v) == rect(0, 25, 333, 775))
        #expect(NamedPlacement.centerThird.cell(portrait: false).rect(in: v) == rect(333, 25, 334, 775))
        #expect(NamedPlacement.lastThird.cell(portrait: false).rect(in: v) == rect(667, 25, 333, 775))
        #expect(NamedPlacement.firstTwoThirds.cell(portrait: false).rect(in: v) == rect(0, 25, 667, 775))
        #expect(NamedPlacement.centerTwoThirds.cell(portrait: false).rect(in: v) == rect(167, 25, 666, 775))
        #expect(NamedPlacement.lastTwoThirds.cell(portrait: false).rect(in: v) == rect(333, 25, 667, 775))
    }

    @Test func ultrawide() {
        #expect(NamedPlacement.firstThird.cell(portrait: false).rect(in: u) == rect(0, 0, 1280, 1575))
        #expect(NamedPlacement.centerTwoThirds.cell(portrait: false).rect(in: u) == rect(640, 0, 2560, 1575))
    }

    @Test func portraitThirdsAreRows() {
        #expect(NamedPlacement.firstThird.cell(portrait: true).rect(in: p) == rect(1000, 0, 1080, 632))
        #expect(NamedPlacement.centerThird.cell(portrait: true).rect(in: p) == rect(1000, 632, 1080, 631))
        #expect(NamedPlacement.lastThird.cell(portrait: true).rect(in: p) == rect(1000, 1263, 1080, 632))
    }

    @Test func noGapsOrOverlaps() {
        for area in [v, u, p] {
            for portrait in [false, true] {
                let r = { (n: NamedPlacement) in n.cell(portrait: portrait).rect(in: area) }
                #expect(r(.leftHalf).maxX == r(.rightHalf).minX)
                #expect(r(.topHalf).maxY == r(.bottomHalf).minY)
                #expect(r(.topLeft).maxX == r(.topRight).minX)
                #expect(r(.topLeft).maxY == r(.bottomLeft).minY)
                #expect(r(.bottomLeft).maxX == r(.bottomRight).minX)
                #expect(r(.firstThird).intersectionArea(r(.centerThird)) == 0)
                #expect(r(.centerThird).intersectionArea(r(.lastThird)) == 0)
                #expect(r(.leftHalf).intersectionArea(r(.rightHalf)) == 0)
                #expect(r(.topLeft).intersectionArea(r(.bottomRight)) == 0)
                let first = r(.firstThird), center = r(.centerThird), last = r(.lastThird)
                if portrait {
                    #expect(first.maxY == center.minY)
                    #expect(center.maxY == last.minY)
                    #expect(first.minY == area.minY && last.maxY == area.maxY)
                    #expect(r(.firstTwoThirds).maxY == last.minY)
                    #expect(r(.lastTwoThirds).minY == first.maxY)
                } else {
                    #expect(first.maxX == center.minX)
                    #expect(center.maxX == last.minX)
                    #expect(first.minX == area.minX && last.maxX == area.maxX)
                    #expect(r(.firstTwoThirds).maxX == last.minX)
                    #expect(r(.lastTwoThirds).minX == first.maxX)
                }
                #expect(r(.maximize) == area)
            }
        }
    }

    @Test func rawValuesAreKebabCase() {
        #expect(NamedPlacement.leftHalf.rawValue == "left-half")
        #expect(NamedPlacement.centerTwoThirds.rawValue == "center-two-thirds")
        #expect(NamedPlacement.allCases.count == 15)
    }
}
