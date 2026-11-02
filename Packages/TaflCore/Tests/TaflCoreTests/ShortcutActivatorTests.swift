import Testing
@testable import TaflCore

@MainActor
@Suite("Shortcut activator")
struct ShortcutActivatorTests {
    private func shortcut(_ text: String) throws -> Shortcut {
        try Shortcut.parse(text).get()
    }

    private func config(shortcuts: [Action: ShortcutBinding] = [:], layouts: [LayoutDefinition] = []) -> Config {
        Config(shortcuts: shortcuts, repeatMode: .displays, gap: 0, step: 30,
               menuBarIcon: true, launchAtLogin: true, layouts: layouts)
    }

    @Test("every default shortcut registers and maps back to its action")
    func registersEveryDefault() {
        let registrar = FakeRegistrar()
        let activator = ShortcutActivator(registrar: registrar)
        let failures = activator.activate(config(), table: .usANSI)
        #expect(failures.isEmpty)
        #expect(registrar.registeredChords.count == 25)
        #expect(Set(registrar.registeredChords).count == 25)
        for (index, action) in Action.allCases.enumerated() {
            #expect(activator.target(for: HotkeyRegistration(id: UInt32(index + 1))) == .action(action))
        }
    }

    @Test("a taken shortcut leaves only that action unbound")
    func takenShortcutLeavesOnlyThatActionUnbound() {
        let registrar = FakeRegistrar()
        registrar.taken = [DefaultShortcuts.chords[.leftHalf]!]
        let activator = ShortcutActivator(registrar: registrar)
        let failures = activator.activate(config(), table: .usANSI)
        #expect(failures == [.action(.leftHalf): .taken])
        #expect(registrar.calls.count == 25)
        #expect(registrar.registeredChords.count == 25)
        #expect(activator.target(for: HotkeyRegistration(id: 24)) != nil)
        #expect(activator.target(for: HotkeyRegistration(id: 25)) == nil)
    }

    @Test("a reload unregisters the whole old set before registering the new one")
    func reloadUnregistersTheWholeOldSetFirst() {
        let registrar = FakeRegistrar()
        let activator = ShortcutActivator(registrar: registrar)
        _ = activator.activate(config(), table: .usANSI)
        let oldCount = registrar.calls.count
        _ = activator.activate(config(), table: .usANSI)
        let second = Array(registrar.calls[oldCount...])
        #expect(second.count == 50)
        #expect(second.prefix(25).allSatisfy { if case .unregister = $0 { true } else { false } })
        #expect(second.suffix(25).allSatisfy { if case .register = $0 { true } else { false } })
        let oldIDs = Set((1...25).map { HotkeyRegistration(id: UInt32($0)) })
        let unregistered = Set(second.prefix(25).compactMap { call -> HotkeyRegistration? in
            if case .unregister(let registration) = call { registration } else { nil }
        })
        #expect(unregistered == oldIDs)
        for id in 1...25 { #expect(activator.target(for: HotkeyRegistration(id: UInt32(id))) == nil) }
        #expect(activator.target(for: HotkeyRegistration(id: 26)) == .action(Action.allCases[0]))
    }

    @Test("a character shortcut that no longer translates after an input source change is reported")
    func untranslatableAfterInputSourceChange() throws {
        let custom = config(shortcuts: [.leftHalf: .custom(try shortcut("ctrl+opt+)"))])
        let azerty = ShortcutActivator(registrar: FakeRegistrar())
        #expect(azerty.activate(custom, table: .frenchAZERTY).isEmpty)
        let us = ShortcutActivator(registrar: FakeRegistrar())
        #expect(us.activate(custom, table: .usANSI)
            == [.action(.leftHalf): .untranslatable("\")\" needs a modifier that isn't in the shortcut; use \"0\" instead")])
    }

    @Test("layout shortcuts register and map back to the layout name")
    func layoutShortcutsRegister() throws {
        let desk = LayoutDefinition(name: "Desk", displays: ["Studio Display"],
                                    shortcut: try shortcut("ctrl+opt+cmd+1"), entries: [])
        let plain = LayoutDefinition(name: "Plain", displays: [], shortcut: nil, entries: [])
        let registrar = FakeRegistrar()
        let activator = ShortcutActivator(registrar: registrar)
        let failures = activator.activate(config(layouts: [desk, plain]), table: .usANSI)
        #expect(failures.isEmpty)
        #expect(registrar.registeredChords.count == 26)
        #expect(activator.target(for: HotkeyRegistration(id: 26)) == .layout("Desk"))
    }

    @Test("unbound actions are not registered")
    func unboundActionsAreSkipped() {
        let registrar = FakeRegistrar()
        let activator = ShortcutActivator(registrar: registrar)
        let failures = activator.activate(config(shortcuts: [.leftHalf: .unbound]), table: .usANSI)
        #expect(failures.isEmpty)
        #expect(registrar.registeredChords.count == 24)
        #expect(!registrar.registeredChords.contains(DefaultShortcuts.chords[.leftHalf]!))
    }

    @Test("deactivateAll unregisters everything and forgets the targets")
    func deactivateAllClearsEverything() {
        let registrar = FakeRegistrar()
        let activator = ShortcutActivator(registrar: registrar)
        _ = activator.activate(config(), table: .usANSI)
        activator.deactivateAll()
        #expect(registrar.calls.count == 50)
        #expect(activator.target(for: HotkeyRegistration(id: 1)) == nil)
    }
}
