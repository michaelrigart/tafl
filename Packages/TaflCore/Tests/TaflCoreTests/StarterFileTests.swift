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

    @Test func aKeyMissingFromTheLayoutIsLeftOutNotWrittenWrongly() {
        var outputs = KeyboardLayoutTable.usANSI.outputs
        outputs[24] = nil
        let text = StarterFile.text(table: KeyboardLayoutTable(outputs))
        #expect(!text.contains("# larger ="))
        #expect(ConfigParser.parse(enabled(text), table: KeyboardLayoutTable(outputs)).isSuccess)
    }
}

extension Result {
    fileprivate var isSuccess: Bool { if case .success = self { true } else { false } }
}
