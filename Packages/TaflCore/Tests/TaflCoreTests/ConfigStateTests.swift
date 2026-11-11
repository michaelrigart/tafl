import Testing
@testable import TaflCore

@Suite("Config state")
struct ConfigStateTests {
    @Test("A bad or unreadable file keeps the last good configuration; a missing one returns to the defaults")
    func statePolicy() {
        var state = ConfigState()
        #expect(state.effective == .defaults)
        #expect(state.status == .defaults)

        state.apply(.text("gap = 4"), table: .usANSI)
        #expect(state.effective.gap == 4)
        #expect(state.status == .loaded)

        state.apply(.text("gap = 4\ngapp = 4"), table: .usANSI)
        #expect(state.effective.gap == 4)
        #expect(state.status == .rejected(ConfigError(line: 2, message: "unknown key \"gapp\"")))

        state.apply(.text("gap = 7"), table: .usANSI)
        state.apply(.missing, table: .usANSI)
        #expect(state.effective == .defaults)
        #expect(state.status == .defaults)

        state.apply(.unreadable("config.toml points to a missing file"), table: .usANSI)
        #expect(state.effective == .defaults)
        #expect(state.status == .rejected(ConfigError(line: nil, message: "config.toml points to a missing file")))
    }

    @Test("An unreadable file keeps a loaded configuration too")
    func unreadableKeepsLoaded() {
        var state = ConfigState()
        state.apply(.text("step = 50"), table: .usANSI)
        state.apply(.unreadable("config.toml can't be read"), table: .usANSI)
        #expect(state.effective.step == 50)
        #expect(state.status == .rejected(ConfigError(line: nil, message: "config.toml can't be read")))
    }

    private let good = """
    gap = 4
    step = 45

    [shortcuts]
    center = "ctrl+opt+cmd+1"

    [[layouts]]
    name = "Desk"
    displays = ["Studio Display"]

      [[layouts.windows]]
      app = "com.apple.Terminal"
      place = "first-third"
    """

    @Test("Whatever the reason for a rejection, the whole last good configuration stays in effect")
    func rejectionKeepsEverything() {
        var state = ConfigState()
        state.apply(.text(good), table: .usANSI)
        let kept = state.effective
        #expect(state.status == .loaded)
        #expect(kept.gap == 4 && kept.step == 45 && kept.layouts.map(\.name) == ["Desk"])

        for bad in ["gap = =", "gap = 4\ngapp = 4", "gap = 400", "[shortcuts]\ncenter = \"ctrl+opt+nope\""] {
            state.apply(.text(bad), table: .usANSI)
            #expect(state.effective == kept, "\(bad)")
            if case .rejected = state.status {} else { Issue.record("Expected \(bad) to be rejected") }
        }
    }

    @Test("A config that stops being valid under a new keyboard layout keeps the one that was in effect")
    func keyboardLayoutChangeRejectsWithoutLosingTheLastGood() {
        var state = ConfigState()
        state.apply(.text(good), table: .usANSI)
        let kept = state.effective
        // The same text, judged again after an input-source change: "1" needs Shift on AZERTY.
        state.apply(.text(good), table: .frenchAZERTY)
        #expect(state.effective == kept)
        #expect(state.status == .rejected(ConfigError(
            line: 5, message: "\"1\" needs a modifier that isn't in the shortcut; use \"&\" instead"
        )))
        state.apply(.text(good), table: .usANSI)
        #expect(state.status == .loaded)
    }

    @Test("A good file after a rejected one is loaded again")
    func recovers() {
        var state = ConfigState()
        state.apply(.text("gap = ="), table: .usANSI)
        state.apply(.text("gap = 3"), table: .usANSI)
        #expect(state.status == .loaded)
        #expect(state.effective.gap == 3)
    }
}
