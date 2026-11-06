import Testing
@testable import TaflCore

@Test func aSizeWithinAPointLeavesTheTargetOrigin() {
    let origin = EdgeAligner.origin(for: rect(0, 25, 500, 775), actualSize: ScreenSize(width: 499.5, height: 775), visible: v)
    #expect(origin == ScreenPoint(x: 0, y: 25))
}

@Test func aSizeAgainstTheLeftEdgeStaysThere() {
    let origin = EdgeAligner.origin(for: rect(0, 25, 500, 775), actualSize: ScreenSize(width: 400, height: 775), visible: v)
    #expect(origin == ScreenPoint(x: 0, y: 25))
}

@Test func aSizeAgainstTheRightEdgeStaysThere() {
    let origin = EdgeAligner.origin(for: rect(500, 25, 500, 775), actualSize: ScreenSize(width: 400, height: 775), visible: v)
    #expect(origin == ScreenPoint(x: 600, y: 25))
}

@Test func aTargetTouchingBothEdgesCentres() {
    let origin = EdgeAligner.origin(for: v, actualSize: ScreenSize(width: 600, height: 775), visible: v)
    #expect(origin == ScreenPoint(x: 200, y: 25))
}

@Test func theBottomEdgeAnchorsTheBottom() {
    let origin = EdgeAligner.origin(for: rect(0, 412, 1000, 388), actualSize: ScreenSize(width: 1000, height: 300), visible: v)
    #expect(origin == ScreenPoint(x: 0, y: 500))
}

@Test func theTopEdgeAnchorsTheTop() {
    let origin = EdgeAligner.origin(for: rect(0, 25, 1000, 388), actualSize: ScreenSize(width: 1000, height: 300), visible: v)
    #expect(origin == ScreenPoint(x: 0, y: 25))
}

@Test func aTargetInsideTheInteriorCentresOnTheTarget() {
    let origin = EdgeAligner.origin(for: rect(200, 200, 400, 400), actualSize: ScreenSize(width: 300, height: 300), visible: v)
    #expect(origin == ScreenPoint(x: 250, y: 250))
}

@Test func theFrameIsKeptInsideTheVisibleFrame() {
    // Centred on a target that overhangs the right edge, the window is pulled back in.
    let origin = EdgeAligner.origin(for: rect(800, 200, 400, 400), actualSize: ScreenSize(width: 300, height: 300), visible: v)
    #expect(origin == ScreenPoint(x: 700, y: 250))
}

@Test func aWindowLargerThanTheVisibleFrameStaysAtTheTargetOrigin() {
    let origin = EdgeAligner.origin(for: rect(0, 25, 500, 775), actualSize: ScreenSize(width: 1200, height: 775), visible: v)
    #expect(origin == ScreenPoint(x: 0, y: 25))
}

@Test func aFrameLeftOfTheVisibleFrameIsPulledBackToItsLeftEdge() {
    let origin = EdgeAligner.origin(
        for: rect(-100, 25, 300, 775), actualSize: ScreenSize(width: 200, height: 775), visible: v, edges: .left
    )
    #expect(origin == ScreenPoint(x: 0, y: 25))
}

@Test func aFramePastTheBottomIsPulledUp() {
    let origin = EdgeAligner.origin(
        for: rect(0, 600, 1000, 400), actualSize: ScreenSize(width: 1000, height: 300), visible: v, edges: .top
    )
    #expect(origin == ScreenPoint(x: 0, y: 500))
}

@Test func aFrameAboveTheTopIsPushedDown() {
    let origin = EdgeAligner.origin(
        for: rect(0, -100, 1000, 400), actualSize: ScreenSize(width: 1000, height: 300), visible: v, edges: .top
    )
    #expect(origin == ScreenPoint(x: 0, y: 25))
}

@Test func theGapKeepsTheFrameOffTheRightAndTopEdgesOnly() {
    // Rectangle's `WindowFrameBounds.constrained`: the gap applies where the frame is pushed in from the
    // right or from the top.
    let right = EdgeAligner.origin(
        for: rect(900, 25, 300, 775), actualSize: ScreenSize(width: 200, height: 775), visible: v, edges: .left, gap: 8
    )
    #expect(right == ScreenPoint(x: 792, y: 25))
    let top = EdgeAligner.origin(
        for: rect(0, 0, 1000, 400), actualSize: ScreenSize(width: 1000, height: 300), visible: v, edges: .top, gap: 8
    )
    #expect(top == ScreenPoint(x: 0, y: 33))
    let left = EdgeAligner.origin(
        for: rect(-100, 25, 300, 775), actualSize: ScreenSize(width: 200, height: 775), visible: v, edges: .left, gap: 8
    )
    #expect(left == ScreenPoint(x: 0, y: 25))
}

@Test func givenEdgesReplaceTheOnesTheTargetTouches() {
    // The target touches the left edge, but the cell it came from was the right half.
    let origin = EdgeAligner.origin(
        for: rect(0, 25, 500, 775), actualSize: ScreenSize(width: 400, height: 775), visible: v, edges: .right
    )
    #expect(origin == ScreenPoint(x: 100, y: 25))
}
