import Testing
@testable import TaflCore

@Suite("Key translation")
struct KeyTranslatorTests {
    private func chord(_ text: String, _ table: KeyboardLayoutTable) throws -> Result<KeyChord, TranslationError> {
        KeyTranslator.chord(for: try Shortcut.parse(text).get(), table: table)
    }

    private func message(_ text: String, _ table: KeyboardLayoutTable) throws -> String? {
        if case .failure(let error) = try chord(text, table) { return error.message }
        return nil
    }

    @Test("US characters map to their key positions")
    func usTranslation() throws {
        #expect(try chord("ctrl+opt+u", .usANSI).get() == KeyChord(keyCode: 32, modifiers: [.control, .option]))
        #expect(try chord("ctrl+opt+=", .usANSI).get().keyCode == 24)
        #expect(try chord("ctrl+opt+left", .usANSI).get().keyCode == 123)
    }

    @Test("AZERTY characters map to the positions that print them")
    func azertyTranslation() throws {
        #expect(try chord("ctrl+opt+)", .frenchAZERTY).get().keyCode == 27)
        #expect(try chord("ctrl+opt+cmd+,", .frenchAZERTY).get().keyCode == 46)
        #expect(try chord("ctrl+opt+m", .frenchAZERTY).get().keyCode == 41)
    }

    @Test("A digit that needs Shift on AZERTY names the key to use instead, and works with Shift")
    func azertyDigitNeedsShift() throws {
        #expect(try message("ctrl+opt+cmd+1", .frenchAZERTY) == "\"1\" needs a modifier that isn't in the shortcut; use \"&\" instead")
        let shifted = try chord("ctrl+opt+cmd+shift+1", .frenchAZERTY).get()
        #expect(shifted.keyCode == 18)
        #expect(shifted.modifiers == [.control, .option, .command, .shift])
    }

    /// The numeric keypad prints its digits and operators without Shift, on every layout.
    private func withKeypad(_ table: KeyboardLayoutTable) -> KeyboardLayoutTable {
        let keypad: [UInt16: String] = [
            82: "0", 83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7", 91: "8", 92: "9",
            65: ",", 67: "*", 69: "+", 75: "/", 78: "-", 81: "=",
        ]
        return KeyboardLayoutTable(table.outputs.merging(keypad.mapValues { KeyOutputs(plain: $0, shifted: $0) }) { current, _ in current })
    }

    @Test("A digit never matches the numeric keypad: on AZERTY it names the top-row key, on US it is the top-row key")
    func digitsAreTheTopRow() throws {
        let azerty = withKeypad(.frenchAZERTY)
        #expect(try message("ctrl+opt+cmd+1", azerty) == "\"1\" needs a modifier that isn't in the shortcut; use \"&\" instead")
        #expect(try chord("ctrl+opt+cmd+&", azerty).get().keyCode == 18)
        #expect(try chord("ctrl+opt+cmd+shift+1", azerty).get().keyCode == 18)
        #expect(try chord("ctrl+opt+cmd+1", withKeypad(.usANSI)).get().keyCode == 18)
    }

    @Test("A character only the numeric keypad prints is not on the layout")
    func keypadOnlyCharacterIsNotOnTheLayout() throws {
        let table = KeyboardLayoutTable(withKeypad(.usANSI).outputs.filter { $0.key != 24 })
        #expect(try message("ctrl+opt+=", table) == "\"=\" isn't on the current keyboard layout")
    }

    @Test("A keypad key has no display shortcut")
    func keypadKeyHasNoShortcut() {
        #expect(KeyTranslator.shortcut(for: KeyChord(keyCode: 83, modifiers: [.control]), table: withKeypad(.usANSI)) == nil)
    }

    @Test("A character the layout lacks is reported")
    func notOnLayout() throws {
        #expect(try message("ctrl+opt+é", .usANSI) == "\"é\" isn't on the current keyboard layout")
    }

    @Test("When two keys print the same character the lowest key code wins")
    func lowestKeyCodeWins() throws {
        let table = KeyboardLayoutTable([
            9: KeyOutputs(plain: "x", shifted: "X"),
            4: KeyOutputs(plain: "x", shifted: "X"),
        ])
        #expect(try chord("ctrl+opt+x", table).get().keyCode == 4)
    }

    @Test("Defaults show as the characters the layout prints on those key positions")
    func defaultsShownPerLayout() throws {
        let smaller = try #require(DefaultShortcuts.chords[.smaller])
        #expect(KeyTranslator.shortcut(for: smaller, table: .frenchAZERTY)?.text == "ctrl+opt+)")
        #expect(KeyTranslator.shortcut(for: smaller, table: .usANSI)?.text == "ctrl+opt+-")
        let pointer = try #require(DefaultShortcuts.chords[.displayUnderPointer])
        #expect(KeyTranslator.shortcut(for: pointer, table: .frenchAZERTY)?.text == "ctrl+opt+cmd+,")
        let left = try #require(DefaultShortcuts.chords[.leftHalf])
        #expect(KeyTranslator.shortcut(for: left, table: .frenchAZERTY)?.text == "ctrl+opt+left")
    }

    @Test("Every default sits on the Rectangle alternate key position, shown here on US")
    func defaultsOnUS() {
        let expected: [Action: String] = [
            .leftHalf: "ctrl+opt+left", .rightHalf: "ctrl+opt+right", .topHalf: "ctrl+opt+up", .bottomHalf: "ctrl+opt+down",
            .topLeft: "ctrl+opt+u", .topRight: "ctrl+opt+i", .bottomLeft: "ctrl+opt+j", .bottomRight: "ctrl+opt+k",
            .firstThird: "ctrl+opt+d", .centerThird: "ctrl+opt+f", .lastThird: "ctrl+opt+g",
            .firstTwoThirds: "ctrl+opt+e", .centerTwoThirds: "ctrl+opt+r", .lastTwoThirds: "ctrl+opt+t",
            .maximize: "ctrl+opt+return", .maximizeHeight: "ctrl+opt+shift+up", .center: "ctrl+opt+c",
            .restore: "ctrl+opt+delete", .larger: "ctrl+opt+=", .smaller: "ctrl+opt+-",
            .displayLeft: "ctrl+opt+cmd+left", .displayRight: "ctrl+opt+cmd+right",
            .displayUp: "ctrl+opt+cmd+up", .displayDown: "ctrl+opt+cmd+down",
            .displayUnderPointer: "ctrl+opt+cmd+m",
        ]
        #expect(expected.count == Action.allCases.count)
        for action in Action.allCases {
            let chord = DefaultShortcuts.chords[action]
            #expect(chord.flatMap { KeyTranslator.shortcut(for: $0, table: .usANSI)?.text } == expected[action], "\(action)")
        }
    }

    @Test("A layout that prints plus unshifted translates ctrl+opt++ to that key")
    func plusKeyTranslates() throws {
        let swedish = KeyboardLayoutTable([27: KeyOutputs(plain: "+", shifted: "?")])
        #expect(try chord("ctrl+opt++", swedish).get().keyCode == 27)
    }

    @Test("A key position the layout does not print has no display shortcut")
    func unknownKeyCodeHasNoShortcut() {
        #expect(KeyTranslator.shortcut(for: KeyChord(keyCode: 99, modifiers: [.control]), table: .usANSI) == nil)
    }

    @Test("Every action has a default and no two actions share one")
    func defaultsAreDistinct() {
        #expect(Action.allCases.count == 25)
        for action in Action.allCases { #expect(DefaultShortcuts.chords[action] != nil, "\(action)") }
        #expect(Set(DefaultShortcuts.chords.values).count == DefaultShortcuts.chords.count)
    }

    @Test("Action names are the spec's config names")
    func actionNames() {
        #expect(Action.leftHalf.rawValue == "left-half")
        #expect(Action.displayUnderPointer.rawValue == "display-under-pointer")
        #expect(Action.allCases.allSatisfy { !$0.summary.isEmpty })
    }
}
