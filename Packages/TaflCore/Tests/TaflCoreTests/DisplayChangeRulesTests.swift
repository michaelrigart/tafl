import Testing
@testable import TaflCore

struct DisplayChangeRulesTests {
    private let app = "com.example.app"

    private func layout(_ place: NamedPlacement, app: String = "com.example.app") -> LayoutDefinition {
        LayoutDefinition(
            name: "Desk",
            displays: [],
            shortcut: nil,
            entries: [LayoutEntry(app: app, title: nil, place: place, display: nil)]
        )
    }

    private func atChange(
        _ snapshot: WindowSnapshot,
        previous: StoredFrame? = nil,
        remembered: StoredFrame? = nil,
        isObserved: Bool = true
    ) -> WindowAtChange {
        WindowAtChange(snapshot: snapshot, previous: previous, remembered: remembered, isObserved: isObserved)
    }

    private func plan(
        old: [Display] = [displayA, displayB],
        new: [Display] = [displayA],
        _ windows: [WindowAtChange],
        claiming: LayoutDefinition? = nil
    ) -> [MoveRequest] {
        DisplayChangeRules.plan(
            oldDisplays: old, newDisplays: new, windows: windows, claiming: claiming, gap: 0
        )
    }

    @Test func layoutBeatsMemory() {
        let w = window(1, frame: rect(0, 25, 400, 300))
        let remembered = StoredFrame(display: displayA.identity, relative: UnitRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        let requests = plan(new: [displayA, displayB], [atChange(w, remembered: remembered)], claiming: layout(.leftHalf))
        #expect(requests == [
            MoveRequest(
                window: w.handle, spec: .named(.leftHalf), display: displayA.identity,
                placement: .leftHalf, cycleStep: 0, source: .displayChange
            ),
        ])
    }

    @Test func claimingLayoutThatDoesNotMatchFallsThroughToMemory() {
        let w = window(1, frame: rect(0, 25, 400, 300))
        let remembered = StoredFrame(display: displayA.identity, relative: UnitRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        let requests = plan([atChange(w, remembered: remembered)], claiming: layout(.leftHalf, app: "other"))
        #expect(requests.map(\.spec) == [.remembered(rect(500, 25, 500, 388))])
    }

    @Test func rememberedSetup() {
        let w = window(1, frame: rect(0, 25, 400, 300))
        let remembered = StoredFrame(display: displayB.identity, relative: UnitRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        let requests = plan(new: [displayA, displayB], [atChange(w, remembered: remembered)])
        #expect(requests == [
            MoveRequest(
                window: w.handle, spec: .remembered(rect(2000, 0, 1000, 775)), display: displayB.identity,
                placement: nil, cycleStep: 0, source: .displayChange
            ),
        ])
    }

    private func recorded(_ frame: ScreenRect, on display: Display) -> StoredFrame {
        StoredFrame(
            display: display.identity,
            relative: frame.relative(to: display.visibleFrame),
            recorded: RecordedFrame(frame: frame, displayFrame: display.frame, visibleFrame: display.visibleFrame)
        )
    }

    @Test func aRememberedFrameIsExactAfterTheDockChangedOnItsDisplay() {
        let w = window(1, frame: rect(0, 25, 400, 300))
        let remembered = recorded(rect(100, 100, 400, 300), on: displayA)
        var docked = displayA
        docked.visibleFrame = rect(100, 25, 900, 775)
        let requests = plan(new: [docked], [atChange(w, remembered: remembered)])
        #expect(requests.map(\.spec) == [.remembered(rect(100, 100, 400, 300))])
    }

    @Test func aRememberedFrameFollowsADisplayThatMovedAndStaysPartlyOffScreen() {
        let w = window(1, frame: rect(0, 25, 400, 300))
        let remembered = recorded(rect(2900, 100, 400, 300), on: displayB)
        var moved = displayB
        moved.frame = rect(-5000, 0, 2000, 1550)
        moved.visibleFrame = moved.frame
        let requests = plan(new: [displayA, moved], [atChange(w, remembered: remembered)])
        #expect(requests.map(\.spec) == [.remembered(rect(-3100, 100, 400, 300))])
    }

    @Test func aRememberedFrameIsMappedWhenItsDisplayChangedResolution() {
        let w = window(1, frame: rect(0, 25, 400, 300))
        let remembered = recorded(rect(1500, 100, 400, 300), on: displayB)
        var smaller = displayB
        smaller.frame = rect(1000, 0, 1000, 775)
        smaller.visibleFrame = smaller.frame
        let requests = plan(new: [displayA, smaller], [atChange(w, remembered: remembered)])
        #expect(requests.map(\.spec) == [.remembered(rect(1250, 50, 200, 150))])
    }

    @Test func aRememberedFrameMostlyOffTheDisplayIsKeptOnScreen() {
        let w = window(1, frame: rect(0, 25, 400, 300))
        let remembered = StoredFrame(display: displayB.identity, relative: UnitRect(x: 0.975, y: 0, width: 0.2, height: 0.2))
        let requests = plan(new: [displayA, displayB], [atChange(w, remembered: remembered)])
        #expect(requests.map(\.spec) == [.remembered(rect(2600, 0, 400, 310))])
    }

    @Test func rememberedSetupStepsAsideForAWindowMacOSRestored() {
        // macOS put the window back at its last frame on this setup: the rule sends no move, and the
        // window is not handed on to the rules below it either.
        let remembered = StoredFrame(display: displayB.identity, relative: UnitRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        let previous = StoredFrame(display: displayA.identity, relative: UnitRect(x: 0, y: 0, width: 0.5, height: 1))
        let restored = window(1, frame: rect(2000, 0, 1000, 775))
        #expect(plan(new: [displayB], [atChange(restored, previous: previous, remembered: remembered)]).isEmpty)
        let offByAPoint = window(2, frame: rect(2001, 0, 1000, 775))
        #expect(plan(new: [displayB], [atChange(offByAPoint, remembered: remembered)]).isEmpty)
        let offByTwo = window(3, frame: rect(2002, 0, 1000, 775))
        #expect(plan(new: [displayB], [atChange(offByTwo, remembered: remembered)]).map(\.spec) == [.remembered(rect(2000, 0, 1000, 775))])
    }

    @Test func aClaimingLayoutStillPlacesAWindowMacOSRestored() {
        let remembered = StoredFrame(display: displayA.identity, relative: UnitRect(x: 0.5, y: 0, width: 0.5, height: 1))
        let restored = window(1, frame: remembered.relative.absolute(in: displayA.visibleFrame))
        #expect(plan(new: [displayA], [atChange(restored, remembered: remembered)], claiming: layout(.leftHalf)).map(\.spec) == [.named(.leftHalf)])
    }

    @Test func recognisedPlacementCarriesOver() {
        let w = window(1, frame: rect(0, 25, 300, 300))
        let previous = StoredFrame(display: displayB.identity, relative: UnitRect(x: 0, y: 0, width: 0.5, height: 1))
        let requests = plan([atChange(w, previous: previous)])
        #expect(requests == [
            MoveRequest(
                window: w.handle, spec: .named(.leftHalf), display: displayA.identity,
                placement: .leftHalf, cycleStep: 0, source: .displayChange
            ),
        ])
    }

    @Test func relativeFallback() {
        let w = window(1, frame: rect(0, 25, 300, 300))
        let relative = UnitRect(x: 0.1, y: 0.2, width: 0.3, height: 0.3)
        let requests = plan([atChange(w, previous: StoredFrame(display: displayB.identity, relative: relative))])
        #expect(requests == [
            MoveRequest(
                window: w.handle, spec: .relative(relative), display: displayA.identity,
                placement: nil, cycleStep: 0, source: .displayChange
            ),
        ])
    }

    @Test func addedDisplayMovesNothing() {
        let w = window(1, frame: rect(0, 25, 300, 300))
        let previous = StoredFrame(display: displayA.identity, relative: UnitRect(x: 0, y: 0, width: 0.5, height: 1))
        #expect(plan(old: [displayA], new: [displayA, displayB], [atChange(w, previous: previous)]).isEmpty)
        #expect(plan(old: [displayA], new: [displayA, displayB], [atChange(w)]).isEmpty)
    }

    @Test func skippedWindows() {
        let previous = StoredFrame(display: displayB.identity, relative: UnitRect(x: 0.1, y: 0.2, width: 0.3, height: 0.3))
        var fullscreen = window(1, frame: rect(0, 25, 300, 300))
        fullscreen.isFullscreen = true
        var minimized = window(2, frame: rect(0, 25, 300, 300))
        minimized.isMinimized = true
        var hidden = window(3, frame: rect(0, 25, 300, 300))
        hidden.isAppHidden = true
        var sheet = window(5, frame: rect(0, 25, 300, 300))
        sheet.isSheet = true
        let unobserved = window(4, frame: rect(0, 25, 300, 300))
        let plain = window(6, frame: rect(0, 25, 300, 300))

        let windows = [
            atChange(fullscreen, previous: previous),
            atChange(minimized, previous: previous),
            atChange(hidden, previous: previous),
            atChange(sheet, previous: previous),
            atChange(unobserved, previous: previous, isObserved: false),
            atChange(plain, previous: previous),
        ]
        let requests = plan(windows, claiming: layout(.leftHalf))
        #expect(requests.map(\.window) == [plain.handle])
        let withoutLayout = plan(windows)
        #expect(withoutLayout.map(\.window) == [plain.handle])
    }

    @Test func rememberedBeatsPreviousOnARemovedDisplay() {
        let w = window(1, frame: rect(0, 25, 300, 300))
        let remembered = StoredFrame(display: displayA.identity, relative: UnitRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        let previous = StoredFrame(display: displayB.identity, relative: UnitRect(x: 0, y: 0, width: 0.5, height: 1))
        let requests = plan([atChange(w, previous: previous, remembered: remembered)])
        #expect(requests == [
            MoveRequest(
                window: w.handle, spec: .remembered(rect(500, 25, 500, 388)), display: displayA.identity,
                placement: nil, cycleStep: 0, source: .displayChange
            ),
        ])
    }

    @Test func placementIsRecognisedOnTheOldDisplay() {
        let portrait = namedDisplay("Portrait", rect(3000, 0, 1000, 1800), serial: 9)
        let w = window(1, frame: rect(0, 25, 300, 300))
        let previous = StoredFrame(
            display: portrait.identity, relative: UnitRect(x: 0, y: 0, width: 1, height: 1.0 / 3)
        )
        let requests = plan(old: [displayA, portrait], [atChange(w, previous: previous)])
        #expect(requests.map(\.spec) == [.named(.firstThird)])
        #expect(requests.map(\.placement) == [.firstThird])
        #expect(requests.map(\.display) == [displayA.identity])
    }

    @Test func placementIsRecognisedWithTheGap() {
        let cell = NamedPlacement.leftHalf.cell(portrait: false)
        let gapped = Gaps.apply(10, to: cell.rect(in: displayB.visibleFrame), cell: cell)
        let w = window(1, frame: rect(0, 25, 300, 300))
        let previous = StoredFrame(display: displayB.identity, relative: gapped.relative(to: displayB.visibleFrame))
        let requests = DisplayChangeRules.plan(
            oldDisplays: [displayA, displayB], newDisplays: [displayA],
            windows: [atChange(w, previous: previous)], claiming: nil, gap: 10
        )
        #expect(requests.map(\.spec) == [.named(.leftHalf)])
        #expect(requests.map(\.placement) == [.leftHalf])
    }
}
