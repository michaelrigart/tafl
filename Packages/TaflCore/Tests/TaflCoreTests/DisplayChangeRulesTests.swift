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
        #expect(requests.map(\.spec) == [.frame(rect(500, 25, 500, 388))])
    }

    @Test func rememberedSetup() {
        let w = window(1, frame: rect(0, 25, 400, 300))
        let remembered = StoredFrame(display: displayB.identity, relative: UnitRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        let requests = plan(new: [displayA, displayB], [atChange(w, remembered: remembered)])
        #expect(requests == [
            MoveRequest(
                window: w.handle, spec: .frame(rect(2000, 0, 1000, 775)), display: displayB.identity,
                placement: nil, cycleStep: 0, source: .displayChange
            ),
        ])
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
}
