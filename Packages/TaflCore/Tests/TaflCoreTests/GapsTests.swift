import Testing
@testable import TaflCore

struct GapsTests {
    private func gapped(_ placement: NamedPlacement, _ gap: Double) -> ScreenRect {
        let cell = placement.cell(portrait: false)
        return Gaps.apply(gap, to: cell.rect(in: v), cell: cell)
    }

    @Test func gapsOnHalvesAndQuarters() {
        #expect(gapped(.leftHalf, 10) == rect(10, 35, 485, 755))
        #expect(gapped(.rightHalf, 10) == rect(505, 35, 485, 755))
        #expect(gapped(.maximize, 10) == rect(10, 35, 980, 755))
        #expect(gapped(.topLeft, 10) == rect(10, 35, 485, 373))
        #expect(gapped(.bottomRight, 10) == rect(505, 418, 485, 372))
    }

    @Test func zeroGapChangesNothing() {
        #expect(gapped(.centerThird, 0) == NamedPlacement.centerThird.cell(portrait: false).rect(in: v))
    }
}
