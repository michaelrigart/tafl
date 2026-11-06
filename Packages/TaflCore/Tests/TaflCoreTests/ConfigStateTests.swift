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

    @Test("A good file after a rejected one is loaded again")
    func recovers() {
        var state = ConfigState()
        state.apply(.text("gap = ="), table: .usANSI)
        state.apply(.text("gap = 3"), table: .usANSI)
        #expect(state.status == .loaded)
        #expect(state.effective.gap == 3)
    }
}
