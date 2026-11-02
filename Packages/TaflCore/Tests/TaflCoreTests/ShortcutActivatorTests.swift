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
        let registered = (1...24).compactMap { activator.target(for: HotkeyRegistration(id: UInt32($0))) }
        #expect(registered == Action.allCases.dropFirst().map(HotkeyTarget.action))
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
        let custom = config(shortcuts: [.leftHalf: .custom(try shortcut("ctrl+opt+)")), .smaller: .unbound])
        let azerty = ShortcutActivator(registrar: FakeRegistrar())
        #expect(azerty.activate(custom, table: .frenchAZERTY).isEmpty)
        let us = ShortcutActivator(registrar: FakeRegistrar())
        #expect(us.activate(custom, table: .usANSI)
            == [.action(.leftHalf): .untranslatable("\")\" needs a modifier that isn't in the shortcut; use \"0\" instead")])
    }

    @Test("switching the input source unregisters the old registration when the new translation fails")
    func inputSourceChangeOnOneActivator() throws {
        let custom = config(shortcuts: [.leftHalf: .custom(try shortcut("ctrl+opt+)")), .smaller: .unbound])
        let registrar = FakeRegistrar()
        let activator = ShortcutActivator(registrar: registrar)
        _ = activator.activate(custom, table: .frenchAZERTY)
        let leftHalfID = try #require((1...24).first { activator.target(for: HotkeyRegistration(id: UInt32($0))) == .action(.leftHalf) })
        _ = activator.activate(custom, table: .usANSI)
        #expect(registrar.calls.contains(.unregister(HotkeyRegistration(id: UInt32(leftHalfID)))))
        #expect(activator.target(for: HotkeyRegistration(id: UInt32(leftHalfID))) == nil)
        #expect(!(25...50).contains { activator.target(for: HotkeyRegistration(id: UInt32($0))) == .action(.leftHalf) })
    }

    @Test("two targets that translate to one chord after an input source change: the later one is not registered")
    func chordClashAfterInputSourceChange() throws {
        let custom = config(shortcuts: [.smaller: .unbound, .leftHalf: .custom(try shortcut("ctrl+opt+-"))])
        let us = FakeRegistrar()
        #expect(ShortcutActivator(registrar: us).activate(custom, table: .usANSI).isEmpty)
        let registrar = FakeRegistrar()
        let activator = ShortcutActivator(registrar: registrar)
        // On AZERTY "-" is key 24, larger's default; left-half precedes larger in Action.allCases.
        let failures = activator.activate(custom, table: .frenchAZERTY)
        #expect(failures == [.action(.larger): .clashes(with: .action(.leftHalf))])
        #expect(Set(registrar.registeredChords).count == registrar.registeredChords.count)
        #expect(registrar.registeredChords.count == 23)
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

    @Test("a layout shortcut that does not translate or is taken is reported")
    func layoutFailures() throws {
        let bad = LayoutDefinition(name: "Bad", displays: [], shortcut: try shortcut("ctrl+opt+cmd+)"), entries: [])
        let held = LayoutDefinition(name: "Held", displays: [], shortcut: try shortcut("ctrl+opt+cmd+1"), entries: [])
        let registrar = FakeRegistrar()
        registrar.taken = [KeyChord(keyCode: 18, modifiers: [.control, .option, .command])]
        let activator = ShortcutActivator(registrar: registrar)
        let failures = activator.activate(config(layouts: [bad, held]), table: .usANSI)
        #expect(failures == [
            .layout("Bad"): .untranslatable("\")\" needs a modifier that isn't in the shortcut; use \"0\" instead"),
            .layout("Held"): .taken,
        ])
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
        #expect(Set(registrar.calls.suffix(25)) == Set((1...25).map { FakeRegistrar.Call.unregister(HotkeyRegistration(id: UInt32($0))) }))
        #expect(registrar.calls.count == 50)
        #expect(activator.target(for: HotkeyRegistration(id: 1)) == nil)
    }
}
