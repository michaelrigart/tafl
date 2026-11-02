import Testing
@testable import TaflCore

@Suite("Shortcut syntax")
struct ShortcutTests {
    private func error(_ text: String) -> String? {
        if case .failure(let error) = Shortcut.parse(text) { return error.message }
        return nil
    }

    @Test("Modifier order and case do not matter; the text is canonical, and the key is stored lowercased")
    func parsesAndCanonicalizes() throws {
        let arrow = try Shortcut.parse("Opt+Ctrl+Left").get()
        #expect(arrow.text == "ctrl+opt+left")
        #expect(arrow.key == .named(.left))
        let letter = try Shortcut.parse("ctrl+opt+U").get()
        #expect(letter.key == .character("u"))
        #expect(letter.modifiers == [.control, .option])
    }

    @Test("Aliases and duplicates collapse to the canonical form")
    func aliasesAndDuplicates() throws {
        #expect(try Shortcut.parse("control+alt+command+shift+Return").get().text == "ctrl+opt+cmd+shift+return")
        #expect(try Shortcut.parse(" ctrl + ctrl + option + = ").get().text == "ctrl+opt+=")
    }

    @Test("Each malformed shortcut gets its own message")
    func syntaxErrors() {
        #expect(error("") == "shortcut is empty")
        #expect(error("hyper+left") == "unknown modifier \"hyper\"")
        #expect(error("ctrl+opt") == "shortcut needs a key")
        #expect(error("left") == "shortcut needs ctrl, opt or cmd")
        #expect(error("ctrl+pgup") == "unknown key \"pgup\"")
    }

    @Test("A trailing plus has no key")
    func trailingPlus() {
        #expect(error("ctrl+opt+") == "shortcut needs a key")
    }

    @Test("Shift alone does not make a shortcut")
    func shiftAloneIsNotEnough() {
        #expect(error("shift+left") == "shortcut needs ctrl, opt or cmd")
    }
}
