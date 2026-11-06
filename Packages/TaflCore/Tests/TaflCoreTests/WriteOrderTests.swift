import Testing
@testable import TaflCore

@Test func crossingDisplaysWritesTheSizeFirst() {
    // The same frames on one display write the position first.
    #expect(WriteOrder.sizeFirst(from: rect(600, 100, 300, 300), to: rect(0, 25, 500, 775), bounds: v, acrossDisplays: true))
}

@Test func anOffScreenWindowWritesTheSizeFirst() {
    #expect(WriteOrder.sizeFirst(from: rect(-200, 100, 300, 300), to: rect(0, 25, 500, 775), bounds: v, acrossDisplays: false))
}

@Test func aWindowOnePointOutsideTheBoundsCountsAsInside() {
    // Inside the 1-point slack, so the overflow comparison decides (moving first overflows 0, resizing first 76).
    #expect(!WriteOrder.sizeFirst(from: rect(-1, 100, 300, 300), to: rect(0, 25, 500, 775), bounds: v, acrossDisplays: false))
    #expect(WriteOrder.sizeFirst(from: rect(-2, 100, 300, 300), to: rect(0, 25, 500, 775), bounds: v, acrossDisplays: false))
}

@Test func movingFirstWhenResizingInPlaceWouldOverflowMore() {
    #expect(!WriteOrder.sizeFirst(from: rect(600, 100, 300, 300), to: rect(0, 25, 500, 775), bounds: v, acrossDisplays: false))
}

@Test func sizeFirstWhenMovingWouldOverflowMore() {
    #expect(WriteOrder.sizeFirst(from: rect(0, 25, 800, 700), to: rect(700, 100, 300, 300), bounds: v, acrossDisplays: false))
}

@Test func equalOverflowPrefersTheSizeFirst() {
    #expect(WriteOrder.sizeFirst(from: rect(100, 100, 300, 300), to: rect(200, 200, 300, 300), bounds: v, acrossDisplays: false))
}

@Test func overflowsWithinOnePointCountAsEqual() {
    // Resizing in place overflows 1 point, moving first 0: not more than 1 apart, so the preference stands.
    #expect(WriteOrder.sizeFirst(from: rect(0, 25, 300, 300), to: rect(0, 25, 1001, 300), bounds: v, acrossDisplays: false))
}
