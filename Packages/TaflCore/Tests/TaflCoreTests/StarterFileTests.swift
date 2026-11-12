import Foundation
import Testing
@testable import TaflCore

@Suite("Starter file")
struct StarterFileTests {
    /// A setting line is a commented key, table header or layout line: `# key = value`, `# [table]`.
    private func isSetting(_ line: Substring) -> Bool {
        line.wholeMatch(of: /# +(\[\[?[a-z.-]+\]\]?|[a-z-]+ = .*)/) != nil
    }

    private func enabled(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { isSetting($0) ? String($0.dropFirst(2)) : String($0) }
            .joined(separator: "\n")
    }

    private func check(_ table: KeyboardLayoutTable) throws {
        let text = StarterFile.text(table: table)
        let result = ConfigParser.parse(enabled(text), table: table)
        guard case .success(let config) = result else {
            Issue.record("starter file did not parse: \(result)\n\(enabled(text))")
            return
        }
        #expect(config.repeatMode == Config.defaults.repeatMode)
        #expect(config.gap == Config.defaults.gap)
        #expect(config.step == Config.defaults.step)
        #expect(config.menuBarIcon == Config.defaults.menuBarIcon)
        #expect(config.launchAtLogin == Config.defaults.launchAtLogin)
        for action in Action.allCases {
            guard case .custom(let shortcut) = config.binding(for: action) else {
                Issue.record("\(action) is not written out")
                continue
            }
            #expect(KeyTranslator.chord(for: shortcut, table: table) == .success(DefaultShortcuts.chords[action]!), "\(action)")
        }
        #expect(config.layouts.count == 1)
    }

    @Test func starterFileParsesToDefaultsOnUS() throws { try check(.usANSI) }
    @Test func starterFileParsesToDefaultsOnAZERTY() throws { try check(.frenchAZERTY) }

    @Test func untouchedStarterFileIsTheDefaults() {
        let text = StarterFile.text(table: .usANSI)
        #expect(ConfigParser.parse(text, table: .usANSI) == .success(Config.defaults))
    }

    @Test func shortcutsShowTheCurrentLayoutsCharacters() {
        #expect(StarterFile.text(table: .usANSI).contains("# smaller = \"ctrl+opt+-\""))
        #expect(StarterFile.text(table: .frenchAZERTY).contains("# smaller = \"ctrl+opt+)\""))
        #expect(StarterFile.text(table: .frenchAZERTY).contains("# display-under-pointer = \"ctrl+opt+cmd+,\""))
    }

    @Test func aKeyMissingFromTheLayoutGetsACommentNotAWrongLine() {
        var outputs = KeyboardLayoutTable.usANSI.outputs
        outputs[24] = nil
        let table = KeyboardLayoutTable(outputs)
        let text = StarterFile.text(table: table)
        #expect(!text.contains("# larger ="))
        #expect(text.contains("# larger: no character on this layout; it stays on its default key"))
        #expect(ConfigParser.parse(enabled(text), table: table).isSuccess)
    }

    /// The file says to remove the `# ` from a line to change it, so one line alone must work.
    @Test(arguments: [KeyboardLayoutTable.usANSI, .frenchAZERTY])
    func uncommentingOneShortcutLineIsEnough(table: KeyboardLayoutTable) {
        let lines = StarterFile.text(table: table).split(separator: "\n", omittingEmptySubsequences: false)
        let start = lines.firstIndex(of: "[shortcuts]")!
        let end = lines.firstIndex { $0.hasPrefix("# An example layout") }!
        let shortcuts = lines[start..<end].filter { $0.wholeMatch(of: /# [a-z-]+ = ".*"/) != nil }
        #expect(shortcuts.count == Action.allCases.count)
        for line in shortcuts {
            let action = String(line.dropFirst(2).prefix { $0 != " " })
            let text = lines.map { $0 == line ? String($0.dropFirst(2)) : String($0) }.joined(separator: "\n")
            guard case .success(let config) = ConfigParser.parse(text, table: table) else {
                Issue.record("uncommenting \(action) alone did not parse")
                continue
            }
            let expected = Action(rawValue: action).flatMap { DefaultShortcuts.chords[$0] }
            guard let act = Action(rawValue: action), case .custom(let shortcut) = config.binding(for: act) else {
                Issue.record("\(action) is not bound by its own line")
                continue
            }
            #expect(KeyTranslator.chord(for: shortcut, table: table) == expected.map { .success($0) })
        }
    }

    @Test(arguments: ["\\", "\""])
    func shortcutValuesAreEscaped(character: String) {
        var outputs = KeyboardLayoutTable.usANSI.outputs
        outputs[24] = KeyOutputs(plain: character, shifted: character)
        let table = KeyboardLayoutTable(outputs)
        let text = StarterFile.text(table: table)
        guard case .success(let config) = ConfigParser.parse(enabled(text), table: table) else {
            Issue.record("did not parse for \(character):\n\(enabled(text))")
            return
        }
        guard case .custom(let shortcut) = config.binding(for: .larger) else {
            Issue.record("larger is not written out")
            return
        }
        #expect(KeyTranslator.chord(for: shortcut, table: table) == .success(DefaultShortcuts.chords[.larger]!))
    }
}

extension Result {
    fileprivate var isSuccess: Bool { if case .success = self { true } else { false } }
}
