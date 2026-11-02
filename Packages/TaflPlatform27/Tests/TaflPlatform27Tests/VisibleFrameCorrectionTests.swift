import CoreGraphics
import Testing
@testable import TaflPlatform27

/// Rectangle v2.0.4's `DockVisibleFrameTests`, with its rects written in AppKit space (origin
/// bottom-left, primary screen 1440 x 900) and flipped to the Accessibility space the
/// correction works in.
private let primaryHeight: CGFloat = 900
private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
private let visibleWithoutDock = CGRect(x: 0, y: 0, width: 1440, height: 875)

private func ax(_ rect: CGRect) -> Coordinates27.AXRect {
    Coordinates27.toAX(.init(rect), primaryHeight: primaryHeight)
}

private func corrected(
    visible: CGRect,
    on screenFrame: CGRect = screen,
    screenFrames: [CGRect]? = nil,
    dock: CGRect?,
    autoHide: Bool = false,
    notchInset: CGFloat = 0
) -> Coordinates27.AXRect {
    VisibleFrameCorrection.corrected(
        visible: ax(visible), frame: ax(screenFrame),
        dock: DockState(isAutoHidden: autoHide, frame: dock.map(ax), screenFrames: (screenFrames ?? [screenFrame]).map(ax)),
        notchInset: notchInset)
}

@Test func missingBottomDockInsetIsAdded() {
    let result = corrected(visible: visibleWithoutDock, dock: CGRect(x: 400, y: 8, width: 640, height: 62))
    #expect(result == ax(CGRect(x: 0, y: 70, width: 1440, height: 805)))
}

@Test func missingLeftDockInsetIsAdded() {
    let result = corrected(visible: visibleWithoutDock, dock: CGRect(x: 8, y: 180, width: 62, height: 540))
    #expect(result == ax(CGRect(x: 70, y: 0, width: 1370, height: 875)))
}

@Test func missingRightDockInsetIsAdded() {
    let result = corrected(visible: visibleWithoutDock, dock: CGRect(x: 1370, y: 180, width: 62, height: 540))
    #expect(result == ax(CGRect(x: 0, y: 0, width: 1370, height: 875)))
}

@Test func accurateReportedInsetIsKeptWhenTheDockFrameDiffersSlightly() {
    let reported = CGRect(x: 0, y: 60, width: 1440, height: 815)
    let result = corrected(visible: reported, dock: CGRect(x: 30, y: 10, width: 1380, height: 53))
    #expect(result == ax(reported))
}

@Test func plausibleReportedInsetIsKeptWhenTheDockFrameDiffersMaterially() {
    let reported = CGRect(x: 0, y: 75, width: 1440, height: 800)
    let result = corrected(visible: reported, dock: CGRect(x: 400, y: 8, width: 640, height: 32))
    #expect(result == ax(reported))
}

@Test func phantomInsetIsReclaimedAfterTheDockMovesToAnotherDisplay() {
    let external = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
    let result = corrected(
        visible: CGRect(x: 0, y: 75, width: 1440, height: 800),
        screenFrames: [screen, external], dock: CGRect(x: 1740, y: 8, width: 1320, height: 62))
    #expect(result == ax(visibleWithoutDock))
}

@Test func theDockOnTheExternalDisplayCorrectsThatDisplay() {
    let external = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
    let result = corrected(
        visible: CGRect(x: 1440, y: 0, width: 1920, height: 1055), on: external,
        screenFrames: [screen, external], dock: CGRect(x: 1740, y: 8, width: 1320, height: 62))
    #expect(result == ax(CGRect(x: 1440, y: 70, width: 1920, height: 985)))
}

@Test func autoHideReclaimsTheStaleInsetAndKeepsTheSmallRevealBoundary() {
    let result = corrected(visible: CGRect(x: 70, y: 4, width: 1370, height: 871), dock: nil, autoHide: true)
    #expect(result == ax(CGRect(x: 0, y: 4, width: 1440, height: 871)))
}

@Test func autoHideReclaimsAStaleBottomInset() {
    let result = corrected(visible: CGRect(x: 0, y: 75, width: 1440, height: 800), dock: nil, autoHide: true)
    #expect(result == ax(visibleWithoutDock))
}

@Test func liveDockClearsAStaleInsetOnTheWrongEdge() {
    let result = corrected(
        visible: CGRect(x: 4, y: 0, width: 1436, height: 875),
        dock: CGRect(x: 400, y: 8, width: 640, height: 62))
    #expect(result == ax(CGRect(x: 0, y: 70, width: 1440, height: 805)))
}

@Test func anUnreadableDockKeepsTheReportedFrame() {
    let reported = CGRect(x: 0, y: 75, width: 1440, height: 800)
    #expect(corrected(visible: reported, dock: nil) == ax(reported))
}

@Test func aCenteredDockFrameIsIgnored() {
    let reported = CGRect(x: 0, y: 75, width: 1440, height: 800)
    #expect(corrected(visible: reported, dock: CGRect(x: 400, y: 300, width: 640, height: 62)) == ax(reported))
}

@Test func anOversizedDockFrameIsIgnoredBeforeReclaimingAnotherDisplay() {
    let external = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
    let reported = CGRect(x: 0, y: 75, width: 1440, height: 800)
    let result = corrected(
        visible: reported, screenFrames: [screen, external], dock: CGRect(x: 1440, y: 0, width: 1920, height: 500))
    #expect(result == ax(reported))
}

@Test func theDockOnADisplayWithANegativeOriginIsCorrected() {
    let external = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    let result = corrected(
        visible: CGRect(x: -1920, y: 0, width: 1920, height: 1055), on: external,
        screenFrames: [external, screen], dock: CGRect(x: -1912, y: 240, width: 62, height: 600))
    #expect(result == ax(CGRect(x: -1850, y: 0, width: 1850, height: 1055)))
}

@Test func aDockOnTheSeamBetweenTwoDisplaysIsIgnored() {
    let upper = CGRect(x: 0, y: 900, width: 1440, height: 900)
    let reported = CGRect(x: 0, y: 75, width: 1440, height: 800)
    let result = corrected(
        visible: reported, screenFrames: [screen, upper], dock: CGRect(x: 400, y: 870, width: 640, height: 60))
    #expect(result == ax(reported))
}

@Test func theMenuBarBoundaryAtTheTopIsKept() {
    let reported = CGRect(x: 0, y: 0, width: 1440, height: 862)
    let result = corrected(visible: reported, dock: CGRect(x: 400, y: 8, width: 640, height: 62))
    #expect(result == ax(CGRect(x: 0, y: 70, width: 1440, height: 792)))
}

@Test func aHiddenMenuBarStillLeavesTheNotchClear() {
    let result = corrected(visible: screen, dock: nil, notchInset: 32)
    #expect(result == ax(CGRect(x: 0, y: 0, width: 1440, height: 868)))
}

@Test func aMenuBarDeeperThanTheNotchIsKept() {
    let reported = CGRect(x: 0, y: 0, width: 1440, height: 862)
    #expect(corrected(visible: reported, dock: nil, notchInset: 32) == ax(reported))
}

@Test func theNotchInsetComposesWithTheDockCorrection() {
    let result = corrected(
        visible: screen, dock: CGRect(x: 400, y: 8, width: 640, height: 62), notchInset: 32)
    #expect(result == ax(CGRect(x: 0, y: 70, width: 1440, height: 798)))
}
