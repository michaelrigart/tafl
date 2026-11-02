import Testing
@testable import TaflCore

struct LayoutPlannerTests {
    private let safari = "com.apple.Safari"
    private let terminal = "com.apple.Terminal"

    private func entry(
        _ app: String,
        title: String? = nil,
        _ place: NamedPlacement,
        display: String? = nil
    ) -> LayoutEntry {
        LayoutEntry(app: app, title: title, place: place, display: display)
    }

    private func layout(_ entries: [LayoutEntry], displays: [String] = []) -> LayoutDefinition {
        LayoutDefinition(name: "Desk", displays: displays, shortcut: nil, entries: entries)
    }

    private func safariWindow(_ id: UInt32, title: String, frame: ScreenRect = rect(0, 0, 400, 300)) -> WindowSnapshot {
        var w = window(id, frame: frame, bundleID: safari)
        w.title = title
        return w
    }

    @Test func firstMatchWins() {
        let definition = layout([
            entry(safari, title: "*Docs*", .lastTwoThirds),
            entry(safari, .firstThird),
        ])
        let docs = safariWindow(1, title: "Team docs")
        let other = safariWindow(2, title: "Inbox")
        #expect(LayoutPlanner.entryIndex(for: docs, in: definition) == 0)
        #expect(LayoutPlanner.entryIndex(for: other, in: definition) == 1)
        #expect(LayoutPlanner.entryIndex(for: window(3, frame: rect(0, 0, 10, 10), bundleID: "x"), in: definition) == nil)
    }

    @Test func windowWithoutBundleIDNeverMatches() {
        var w = window(1, frame: rect(0, 0, 10, 10))
        w.bundleID = nil
        #expect(LayoutPlanner.entryIndex(for: w, in: layout([entry("com.example.app", .firstThird)])) == nil)
    }

    @Test func stacking() {
        let definition = layout([entry(terminal, .firstThird)])
        let windows = [
            window(1, frame: rect(0, 0, 400, 300), bundleID: terminal),
            window(2, frame: rect(100, 100, 400, 300), bundleID: terminal),
        ]
        let requests = LayoutPlanner.requests(
            definition, windows: windows, displays: [displayA, displayB], source: .layout("Desk")
        )
        #expect(requests.map(\.window) == windows.map(\.handle))
        #expect(requests.map(\.spec) == [.named(.firstThird), .named(.firstThird)])
        #expect(requests.map(\.display) == [displayA.identity, displayA.identity])
        #expect(requests.allSatisfy { $0.placement == .firstThird && $0.cycleStep == 0 })
        #expect(requests.allSatisfy { $0.source == .layout("Desk") })
    }

    @Test func entryDisplayChoice() {
        let onA = window(1, frame: rect(0, 0, 400, 300), bundleID: terminal)
        let displays = [displayA, displayB]
        func target(_ definition: LayoutDefinition) -> DisplayIdentity? {
            LayoutPlanner.requests(definition, windows: [onA], displays: displays, source: .layout("Desk")).first?.display
        }
        // Explicit display wins over the layout's only display.
        #expect(target(layout([entry(terminal, .firstThird, display: "Desk")], displays: ["Built-in"])) == displayB.identity)
        // The layout's only display.
        #expect(target(layout([entry(terminal, .firstThird)], displays: ["Desk"])) == displayB.identity)
        // A shortcut-only layout uses the window's current display.
        #expect(target(layout([entry(terminal, .firstThird)], displays: [])) == displayA.identity)
        // A layout with several displays and no entry display uses the current one.
        #expect(target(layout([entry(terminal, .firstThird)], displays: ["Built-in", "Desk"])) == displayA.identity)
        // A disconnected named display falls back to the current display.
        #expect(target(layout([entry(terminal, .firstThird, display: "Gone")], displays: [])) == displayA.identity)
        #expect(target(layout([entry(terminal, .firstThird)], displays: ["Gone"])) == displayA.identity)
    }

    @Test func currentDisplayFollowsTheWindow() {
        let onB = window(1, frame: rect(1200, 100, 400, 300), bundleID: terminal)
        let requests = LayoutPlanner.requests(
            layout([entry(terminal, .firstThird)]), windows: [onB], displays: [displayA, displayB], source: .layout("Desk")
        )
        #expect(requests.first?.display == displayB.identity)
    }

    @Test func skipsMinimizedAndHidden() {
        var minimized = window(1, frame: rect(0, 0, 400, 300), bundleID: terminal)
        minimized.isMinimized = true
        var hidden = window(2, frame: rect(0, 0, 400, 300), bundleID: terminal)
        hidden.isAppHidden = true
        let visible = window(3, frame: rect(0, 0, 400, 300), bundleID: terminal)
        let requests = LayoutPlanner.requests(
            layout([entry(terminal, .firstThird)]),
            windows: [minimized, hidden, visible],
            displays: [displayA],
            source: .newWindow(layout: "Desk")
        )
        #expect(requests.map(\.window) == [visible.handle])
        #expect(requests.first?.source == .newWindow(layout: "Desk"))
    }

    @Test func windowsMatchingNoEntryAreLeftAlone() {
        let other = window(1, frame: rect(0, 0, 400, 300), bundleID: "com.other")
        let requests = LayoutPlanner.requests(
            layout([entry(terminal, .firstThird)]), windows: [other], displays: [displayA], source: .layout("Desk")
        )
        #expect(requests.isEmpty)
    }

    @Test func claimingIsExact() {
        let desk = layout([], displays: ["Desk"])
        let shortcutOnly = LayoutDefinition(name: "Other", displays: [], shortcut: nil, entries: [])
        #expect(LayoutPlanner.claiming([shortcutOnly, desk], displays: [displayB]) == desk)
        #expect(LayoutPlanner.claiming([shortcutOnly, desk], displays: [displayA, displayB]) == nil)
        #expect(LayoutPlanner.claiming([shortcutOnly], displays: []) == nil)
    }
}
