import TaflCore

public enum KeyboardLayout27 {
    @MainActor
    public static func table() -> KeyboardLayoutTable {
        table(from: KeyboardLayoutReader27.currentLayout())
    }

    /// Keys with no printable output (empty, control or whitespace other than space) are left out.
    public static func table(from raw: [UInt16: (plain: String, shifted: String)]) -> KeyboardLayoutTable {
        KeyboardLayoutTable(raw.compactMapValues { outputs in
            guard isPrintable(outputs.plain) else { return nil }
            return KeyOutputs(plain: outputs.plain, shifted: outputs.shifted)
        })
    }

    private static func isPrintable(_ output: String) -> Bool {
        !output.isEmpty && !output.unicodeScalars.contains { scalar in
            scalar != " " && (scalar.properties.generalCategory == .control || scalar.properties.isWhitespace)
        }
    }
}
