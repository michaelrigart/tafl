import Testing
@testable import TaflCore

private func clamp(
    written: WritePart = .position, before: ScreenRect, after: ScreenRect
) -> AdjustmentCase {
    AdjustmentCase(written: written, before: before, after: after, targetVisible: v, displays: [displayA, displayB])
}

@Test func aSizeClampedToTheNewDisplayIsExplained() {
    let case_ = clamp(before: rect(1100, 100, 1200, 775), after: rect(0, 25, 1000, 775))
    #expect(MacOSAdjustment.sizeClampedToDisplay.explains(case_))
}

@Test func aClampOffByAPointIsExplained() {
    #expect(MacOSAdjustment.sizeClampedToDisplay.explains(clamp(before: rect(1100, 100, 1200, 775), after: rect(0, 25, 1001, 775))))
}

@Test func aClampOffByTwoPointsIsNot() {
    #expect(!MacOSAdjustment.sizeClampedToDisplay.explains(clamp(before: rect(1100, 100, 1200, 775), after: rect(0, 25, 1002, 775))))
}

@Test func aShrinkWithinOneDisplayIsNot() {
    // The same numbers as a clamp, but the window never left A.
    #expect(!MacOSAdjustment.sizeClampedToDisplay.explains(clamp(before: rect(100, 100, 800, 600), after: rect(0, 25, 500, 500))))
    #expect(!MacOSAdjustment.sizeClampedToDisplay.explains(clamp(before: rect(100, 50, 1200, 775), after: rect(0, 25, 1000, 775))))
}

@Test func aSizeWriteIsNeverExplainedByIt() {
    let case_ = clamp(written: .size, before: rect(1100, 100, 1200, 775), after: rect(0, 25, 1000, 775))
    #expect(!MacOSAdjustment.sizeClampedToDisplay.explains(case_))
}

@Test func theClampIsToTheDisplayTheWindowLandedOn() {
    // Landing on B, whose visible frame is larger, a width of 1000 is not a clamp of 1200.
    #expect(!MacOSAdjustment.sizeClampedToDisplay.explains(clamp(before: rect(100, 100, 1200, 775), after: rect(1000, 0, 1000, 775))))
    #expect(MacOSAdjustment.sizeClampedToDisplay.explains(clamp(before: rect(100, 100, 500, 1700), after: rect(1000, 0, 500, 1550))))
}
