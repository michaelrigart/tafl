import Foundation

public enum TranslationError: Error, Equatable, Sendable {
    case needsModifier(character: String, useInstead: String)
    case notOnLayout(String)

    public var message: String {
        switch self {
        case .needsModifier(let character, let useInstead):
            "\"\(character)\" needs a modifier that isn't in the shortcut; use \"\(useInstead)\" instead"
        case .notOnLayout(let character):
            "\"\(character)\" isn't on the current keyboard layout"
        }
    }
}

public enum KeyTranslator {
    /// The numeric keypad's key codes (kVK_ANSI_Keypad*). A character in a shortcut means the main
    /// keys, so these never match one: the keypad's 1 prints "1" without Shift, where the top-row
    /// key on AZERTY needs it.
    static let keypadKeyCodes: Set<UInt16> = [65, 67, 69, 71, 75, 76, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92]

    public static func chord(for shortcut: Shortcut, table: KeyboardLayoutTable) -> Result<KeyChord, TranslationError> {
        switch shortcut.key {
        case .named(let named):
            return .success(KeyChord(keyCode: named.keyCode, modifiers: shortcut.modifiers))
        case .character(let character):
            let codes = table.outputs.keys.filter { !keypadKeyCodes.contains($0) }.sorted()
            if let code = codes.first(where: { table.outputs[$0]?.plain.lowercased() == character }) {
                return .success(KeyChord(keyCode: code, modifiers: shortcut.modifiers))
            }
            if let code = codes.first(where: { table.outputs[$0]?.shifted == character }) {
                if shortcut.modifiers.contains(.shift) {
                    return .success(KeyChord(keyCode: code, modifiers: shortcut.modifiers))
                }
                return .failure(.needsModifier(character: character, useInstead: table.outputs[code]?.plain ?? character))
            }
            return .failure(.notOnLayout(character))
        }
    }

    public static func shortcut(for chord: KeyChord, table: KeyboardLayoutTable) -> Shortcut? {
        if let named = NamedKey.allCases.first(where: { $0.keyCode == chord.keyCode }) {
            return Shortcut(modifiers: chord.modifiers, key: .named(named))
        }
        guard !keypadKeyCodes.contains(chord.keyCode), let output = table.outputs[chord.keyCode] else { return nil }
        return Shortcut(modifiers: chord.modifiers, key: .character(output.plain.lowercased()))
    }
}
