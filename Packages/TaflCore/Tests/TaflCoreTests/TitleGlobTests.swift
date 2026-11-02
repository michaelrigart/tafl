import Testing
@testable import TaflCore

struct TitleGlobTests {
    @Test func globs() {
        #expect(TitleGlob.matches("*Docs*", "Team docs – Safari"))
        #expect(TitleGlob.matches("?ail", "Mail"))
        #expect(!TitleGlob.matches("Docs", "My Docs"))
        #expect(TitleGlob.matches("Notes\\?", "Notes?"))
        #expect(!TitleGlob.matches("Notes\\?", "Notes!"))
        #expect(TitleGlob.escape("a*b?c\\") == "a\\*b\\?c\\\\")
    }

    @Test func starMatchesEmptyAndBacktracks() {
        #expect(TitleGlob.matches("*", ""))
        #expect(TitleGlob.matches("a*b*c", "abc"))
        #expect(TitleGlob.matches("a*b*c", "axxbyyc"))
        #expect(!TitleGlob.matches("a*b*c", "axxbyy"))
    }

    @Test func questionMarkIsOneCharacterNotOneByte() {
        #expect(TitleGlob.matches("?", "é"))
        #expect(TitleGlob.matches("?", "👩‍💻"))
        #expect(!TitleGlob.matches("?", ""))
        #expect(!TitleGlob.matches("?", "ab"))
    }

    @Test func escapedStarIsLiteral() {
        #expect(TitleGlob.matches("a\\*b", "a*b"))
        #expect(!TitleGlob.matches("a\\*b", "axb"))
    }

    @Test func trailingBackslashMatchesBackslash() {
        #expect(TitleGlob.matches("C:\\", "C:\\"))
        #expect(!TitleGlob.matches("C:\\", "C:"))
    }

    @Test func escapedTitleMatchesItself() {
        let title = "Report *final*? \\ draft"
        #expect(TitleGlob.matches(TitleGlob.escape(title), title))
        #expect(!TitleGlob.matches(TitleGlob.escape(title), "Report xfinalx? \\ draft"))
    }

    @Test func caseInsensitive() {
        #expect(TitleGlob.matches("docs", "DOCS"))
        #expect(TitleGlob.matches("*ÉCOLE*", "école"))
    }
}
