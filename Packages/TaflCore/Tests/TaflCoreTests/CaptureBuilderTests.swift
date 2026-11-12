import Testing
@testable import TaflCore

@Suite("Capture builder")
struct CaptureBuilderTests {
    private let terminal = "com.apple.Terminal"
    private let safari = "com.apple.Safari"

    private let leftHalfA = rect(0, 25, 500, 775)
    private let rightHalfA = rect(500, 25, 500, 775)

    private func layout(_ text: String) -> LayoutDefinition? {
        guard case .success(let config) = ConfigParser.parse(text, table: .usANSI) else { return nil }
        return config.layouts.first
    }

    private func titled(_ id: UInt32, _ title: String, _ frame: ScreenRect, bundleID: String) -> WindowSnapshot {
        var w = window(id, frame: frame, bundleID: bundleID)
        w.title = title
        return w
    }

    @Test func captureRoundTrips() throws {
        let windows = [
            window(1, frame: leftHalfA, bundleID: terminal),
            window(2, frame: rightHalfA, bundleID: safari),
            window(3, frame: rect(30, 60, 333, 222), bundleID: "com.example.free"),
        ]
        let snippet = CaptureBuilder.snippet(windows: windows, displays: [displayA], gap: 0)
        let parsed = try #require(layout(snippet), "snippet did not parse:\n\(snippet)")
        #expect(parsed.name == "Captured")
        #expect(parsed.displays == ["Built-in"])
        #expect(parsed.entries.map(\.app) == [terminal, safari])
        #expect(parsed.entries.map(\.place) == [.leftHalf, .rightHalf])
        #expect(parsed.entries.allSatisfy { $0.title == nil && $0.display == nil })
        #expect(snippet.contains("# com.example.free: no recognised placement"))
    }

    @Test func captureUsesTitlesOnlyWhenNeeded() throws {
        let windows = [
            titled(1, "One", leftHalfA, bundleID: terminal),
            titled(2, "Two", leftHalfA, bundleID: terminal),
            titled(3, "Docs", leftHalfA, bundleID: safari),
            titled(4, "Mail", rightHalfA, bundleID: safari),
        ]
        let snippet = CaptureBuilder.snippet(windows: windows, displays: [displayA], gap: 0)
        let parsed = try #require(layout(snippet))
        // Terminal's windows share a placement: one entry, no title. Safari's differ: titled.
        #expect(parsed.entries.map(\.app) == [terminal, safari, safari])
        #expect(parsed.entries.map(\.title) == [nil, "Docs", "Mail"])
    }

    @Test func aWindowWithoutAPlacementForcesTitlesOnItsApp() throws {
        let windows = [
            titled(1, "Placed", leftHalfA, bundleID: terminal),
            titled(2, "Loose", rect(10, 40, 321, 200), bundleID: terminal),
        ]
        let snippet = CaptureBuilder.snippet(windows: windows, displays: [displayA], gap: 0)
        let parsed = try #require(layout(snippet))
        #expect(parsed.entries.map(\.title) == ["Placed"])
        #expect(parsed.entries.map(\.place) == [.leftHalf])
        #expect(LayoutPlanner.entryIndex(for: windows[1], in: parsed) == nil)
        #expect(snippet.contains("# \(terminal): no recognised placement"))
    }

    @Test func captureSeparatesDisplays() throws {
        let onA = titled(1, "On A", leftHalfA, bundleID: terminal)
        let onB = titled(2, "On B", rect(1000, 0, 1000, 1550), bundleID: terminal)
        let snippet = CaptureBuilder.snippet(windows: [onB, onA], displays: [displayA, displayB], gap: 0)
        let parsed = try #require(layout(snippet), "snippet did not parse:\n\(snippet)")
        #expect(parsed.displays == ["Built-in", "Desk"])
        #expect(parsed.entries.map(\.display) == ["Built-in", "Desk"])
        #expect(parsed.entries.map(\.place) == [.leftHalf, .leftHalf])
        #expect(LayoutPlanner.entryIndex(for: onA, in: parsed) == 0)
        #expect(LayoutPlanner.entryIndex(for: onB, in: parsed) == 1)
    }

    @Test func capturedTitlesMatchOnlyTheirWindow() throws {
        let question = titled(1, "Notes?", leftHalfA, bundleID: "com.apple.Notes")
        let bang = titled(2, "Notes!", rightHalfA, bundleID: "com.apple.Notes")
        let snippet = CaptureBuilder.snippet(windows: [question, bang], displays: [displayA], gap: 0)
        let parsed = try #require(layout(snippet), "snippet did not parse:\n\(snippet)")
        #expect(parsed.entries.count == 2)
        #expect(LayoutPlanner.entryIndex(for: question, in: parsed) == 0)
        #expect(LayoutPlanner.entryIndex(for: bang, in: parsed) == 1)
    }

    @Test func quotesBackslashesAndControlCharactersSurviveTheRoundTrip() throws {
        let odd = titled(1, "say \"hi\" \\ C:\\x\ttab", leftHalfA, bundleID: terminal)
        let other = titled(2, "other", rightHalfA, bundleID: terminal)
        let snippet = CaptureBuilder.snippet(windows: [odd, other], displays: [displayA], gap: 0)
        let parsed = try #require(layout(snippet), "snippet did not parse:\n\(snippet)")
        #expect(LayoutPlanner.entryIndex(for: odd, in: parsed) == 0)
        #expect(LayoutPlanner.entryIndex(for: other, in: parsed) == 1)
    }

    @Test func aTitleThatCannotTellTwoWindowsApartIsCommentedNotWritten() throws {
        let first = titled(1, "Same", leftHalfA, bundleID: terminal)
        let second = titled(2, "SAME", rightHalfA, bundleID: terminal)
        let snippet = CaptureBuilder.snippet(windows: [first, second], displays: [displayA], gap: 0)
        let parsed = try #require(layout(snippet), "snippet did not parse:\n\(snippet)")
        #expect(parsed.entries.map(\.place) == [.leftHalf])
        #expect(snippet.contains("# \(terminal): same title as another window, can't be told apart"))
    }

    @Test func sameTitleInTheSamePlacementIsOneEntry() throws {
        let first = titled(1, "Same", leftHalfA, bundleID: terminal)
        let second = titled(2, "same", leftHalfA, bundleID: terminal)
        let loose = titled(3, "Other", rect(10, 40, 321, 200), bundleID: terminal)
        let snippet = CaptureBuilder.snippet(windows: [first, second, loose], displays: [displayA], gap: 0)
        let parsed = try #require(layout(snippet))
        #expect(parsed.entries.count == 1)
        #expect(!snippet.contains("same title"))
    }

    @Test func repeatedDisplayNamesUseIdentifiers() throws {
        let first = namedDisplay("Studio", rect(0, 0, 1000, 800), serial: 11)
        let second = namedDisplay("Studio", rect(1000, 0, 1000, 800), serial: 22)
        let onSecond = window(1, frame: rect(1000, 0, 500, 800), bundleID: terminal)
        let snippet = CaptureBuilder.snippet(windows: [onSecond], displays: [first, second], gap: 0)
        let parsed = try #require(layout(snippet), "snippet did not parse:\n\(snippet)")
        #expect(parsed.displays == [first.identity.identifier, second.identity.identifier])
        #expect(parsed.entries.map(\.display) == [second.identity.identifier])
    }

    @Test func gapIsUsedToRecognise() throws {
        let gapped = window(1, frame: rect(8, 33, 488, 759), bundleID: terminal)
        let snippet = CaptureBuilder.snippet(windows: [gapped], displays: [displayA], gap: 8)
        #expect(layout(snippet)?.entries.map(\.place) == [.leftHalf])
    }

    @Test func windowsThatCannotBePlacedAreLeftOut() {
        var minimized = window(1, frame: leftHalfA, bundleID: terminal)
        minimized.isMinimized = true
        let snippet = CaptureBuilder.snippet(windows: [minimized], displays: [displayA], gap: 0)
        #expect(!snippet.contains(terminal))
    }
}
