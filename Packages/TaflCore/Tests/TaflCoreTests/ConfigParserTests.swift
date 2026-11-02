import Testing
@testable import TaflCore

@Suite("Config parser")
struct ConfigParserTests {
    private func config(_ text: String, table: KeyboardLayoutTable = .usANSI) -> Config? {
        if case .success(let config) = ConfigParser.parse(text, table: table) { return config }
        return nil
    }

    private func error(_ text: String, table: KeyboardLayoutTable = .usANSI) -> ConfigError? {
        if case .failure(let error) = ConfigParser.parse(text, table: table) { return error }
        return nil
    }

    private func expect(_ text: String, line: Int?, _ message: String, table: KeyboardLayoutTable = .usANSI,
                        sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(error(text, table: table) == ConfigError(line: line, message: message), sourceLocation: sourceLocation)
    }

    private let desk = """
    [[layouts]]
    name = "Desk"
    displays = ["Studio Display"]   # applies automatically when exactly these are connected
    shortcut = "ctrl+opt+cmd+1"     # optional

      [[layouts.windows]]
      app = "com.apple.Terminal"
      place = "first-third"

      [[layouts.windows]]
      app = "com.apple.Safari"
      title = "*Docs*"              # optional glob on the window title
      place = "last-two-thirds"
      display = "Studio Display"    # required when the layout names more than one display
    """

    @Test("An empty file is the defaults, and every action is on its standard shortcut")
    func emptyFileIsDefaults() {
        #expect(config("") == .defaults)
        #expect(Config.defaults.binding(for: .leftHalf) == .standard)
    }

    @Test("The spec's layout example with every setting parses to the expected Config")
    func fullFile() throws {
        let text = """
        repeat = "sizes"
        gap = 4
        step = 20
        menu-bar-icon = false

        [shortcuts]
        restore = "none"
        center = "ctrl+opt+shift+c"

        \(desk)
        """
        let parsed = try #require(config(text))
        let expected = Config(
            shortcuts: [
                .restore: .unbound,
                .center: .custom(try Shortcut.parse("ctrl+opt+shift+c").get()),
            ],
            repeatMode: .sizes,
            gap: 4,
            step: 20,
            menuBarIcon: false,
            launchAtLogin: true,
            layouts: [
                LayoutDefinition(
                    name: "Desk",
                    displays: ["Studio Display"],
                    shortcut: try Shortcut.parse("ctrl+opt+cmd+1").get(),
                    entries: [
                        LayoutEntry(app: "com.apple.Terminal", title: nil, place: .firstThird, display: nil),
                        LayoutEntry(app: "com.apple.Safari", title: "*Docs*", place: .lastTwoThirds, display: "Studio Display"),
                    ]
                ),
            ]
        )
        #expect(parsed == expected)
        #expect(parsed.binding(for: .restore) == .unbound)
        #expect(parsed.binding(for: .maximize) == .standard)
    }

    @Test("gap and step accept floats as well as integers")
    func floatsAreNumbers() {
        let parsed = config("gap = 2.5\nstep = 12")
        #expect(parsed?.gap == 2.5)
        #expect(parsed?.step == 12)
    }

    @Test("A TOML syntax error keeps its line")
    func syntaxErrorKeepsItsLine() {
        #expect(error("a = 1\ngap = = 4")?.line == 2)
    }

    @Test("A syntax error moves the line prefix out of the message")
    func syntaxErrorMessageHasNoPrefix() throws {
        let failure = try #require(error("a = 1\ngap = = 4"))
        #expect(!failure.message.hasPrefix("(Line"))
        #expect(failure.description == "Line 2: \(failure.message)")
    }

    @Test("A TOML error without a line is kept whole, with no line")
    func errorWithoutLine() {
        let failure = ConfigError(tomlDescription: "The given data was not valid UTF8.")
        #expect(failure == ConfigError(line: nil, message: "The given data was not valid UTF8."))
        #expect(failure.description == "The given data was not valid UTF8.")
    }

    @Test("An unknown key is an error at every level, so typos never pass")
    func unknownKeys() {
        expect("gap = 4\ngapp = 4", line: 2, "unknown key \"gapp\"")
        expect("[[layouts]]\nname = \"A\"\ndisplays = [\"X\"]\ncolour = 1", line: 4, "unknown key \"colour\"")
        expect("[[layouts]]\nname = \"A\"\ndisplays = [\"X\"]\n[[layouts.windows]]\napp = \"a\"\nplace = \"maximize\"\nsize = 1",
               line: 7, "unknown key \"size\"")
    }

    @Test("A value of the wrong type names the key and the type it needs")
    func wrongTypes() {
        expect("repeat = 3", line: 1, "\"repeat\" must be a string")
        expect("gap = \"wide\"", line: 1, "\"gap\" must be a number")
        expect("\n\nstep = true", line: 3, "\"step\" must be a number")
        expect("menu-bar-icon = \"yes\"", line: 1, "\"menu-bar-icon\" must be true or false")
        expect("launch-at-login = 1", line: 1, "\"launch-at-login\" must be true or false")
        expect("[[layouts]]\nname = 3", line: 2, "\"name\" must be a string")
        expect("[[layouts]]\nname = \"A\"\ndisplays = \"X\"", line: 3, "\"displays\" must be a list of strings")
        expect("[[layouts]]\nname = \"A\"\ndisplays = [\"X\", 2]", line: 3, "\"displays\" must be a list of strings")
        expect("[shortcuts]\nrestore = 4", line: 2, "\"restore\" must be a string")
        expect("[[layouts]]\nname = \"A\"\ndisplays = [\"X\"]\n[[layouts.windows]]\napp = 1\nplace = \"maximize\"",
               line: 5, "\"app\" must be a string")
    }

    @Test("A bad string escape reports TOMLDecoder's own text at its line, not a type error")
    func badEscape() throws {
        let failure = try #require(error("gap = 1\n[[layouts]]\nname = \"a\\qb\""))
        #expect(failure.line == 3)
        #expect(!failure.message.contains("must be"))
    }

    @Test("repeat accepts three words and nothing else")
    func repeatValues() {
        #expect(config("repeat = \"none\"")?.repeatMode == RepeatMode.none)
        #expect(config("repeat = \"displays\"")?.repeatMode == .displays)
        expect("\nrepeat = \"always\"", line: 2, "repeat must be \"displays\", \"sizes\" or \"none\"")
    }

    @Test("gap and step are range checked at both ends")
    func ranges() {
        expect("gap = 101", line: 1, "gap must be between 0 and 100")
        expect("gap = -1", line: 1, "gap must be between 0 and 100")
        expect("step = 0", line: 1, "step must be between 1 and 500")
        expect("gap = 1\nstep = 501", line: 2, "step must be between 1 and 500")
        #expect(config("gap = 100\nstep = 500")?.step == 500)
        #expect(config("gap = 0\nstep = 1")?.gap == 0)
    }

    @Test("An unknown action in [shortcuts] is named")
    func unknownAction() {
        expect("[shortcuts]\nleft-halve = \"ctrl+opt+left\"", line: 2, "unknown action \"left-halve\"")
    }

    @Test("Shortcut syntax errors carry Task 6's message at the key's line")
    func shortcutSyntax() {
        expect("[shortcuts]\ncenter = \"hyper+c\"", line: 2, "unknown modifier \"hyper\"")
        expect("[shortcuts]\n\ncenter = \"\"", line: 3, "shortcut is empty")
        expect("[shortcuts]\ncenter = \"left\"", line: 2, "shortcut needs ctrl, opt or cmd")
    }

    @Test("A shortcut the layout can't type has Task 6's translation message at the key's line")
    func azertyModifierErrorHasLine() {
        let message = "\"1\" needs a modifier that isn't in the shortcut; use \"&\" instead"
        expect("[shortcuts]\nleft-half = \"ctrl+opt+1\"", line: 2, message, table: .frenchAZERTY)
        #expect(config("[shortcuts]\nleft-half = \"ctrl+opt+shift+1\"", table: .frenchAZERTY) != nil)
    }

    @Test("Two actions on one chord are an error at the later one, and a default counts while its action is on it")
    func duplicateChords() {
        expect("[shortcuts]\ncenter = \"ctrl+opt+left\"", line: 2, "\"ctrl+opt+left\" is also used by left-half")
        expect("[shortcuts]\nmaximize = \"ctrl+opt+q\"\ncenter = \"opt+ctrl+Q\"", line: 3, "\"ctrl+opt+q\" is also used by maximize")
        // Moving left-half away frees its default chord; unbinding does too.
        #expect(config("[shortcuts]\nleft-half = \"ctrl+opt+shift+left\"\ncenter = \"ctrl+opt+left\"") != nil)
        #expect(config("[shortcuts]\nleft-half = \"none\"\ncenter = \"ctrl+opt+left\"") != nil)
        // An action may be set to its own default.
        #expect(config("[shortcuts]\nleft-half = \"ctrl+opt+left\"") != nil)
    }

    @Test("A layout shortcut clashes with a default, an action and another layout, at the later one")
    func layoutChordClashes() {
        expect("[[layouts]]\nname = \"A\"\nshortcut = \"ctrl+opt+left\"", line: 3,
               "\"ctrl+opt+left\" is also used by left-half")
        expect("[shortcuts]\ncenter = \"ctrl+opt+cmd+1\"\n[[layouts]]\nname = \"A\"\nshortcut = \"ctrl+opt+cmd+1\"", line: 5,
               "\"ctrl+opt+cmd+1\" is also used by center")
        expect("[[layouts]]\nname = \"A\"\nshortcut = \"ctrl+opt+cmd+1\"\n[[layouts]]\nname = \"B\"\nshortcut = \"ctrl+opt+cmd+1\"",
               line: 6, "\"ctrl+opt+cmd+1\" is also used by layout \"A\"")
        // An action section placed after the layout makes the action the later one.
        expect("[[layouts]]\nname = \"A\"\nshortcut = \"ctrl+opt+cmd+1\"\n[shortcuts]\ncenter = \"ctrl+opt+cmd+1\"", line: 5,
               "\"ctrl+opt+cmd+1\" is also used by layout \"A\"")
    }

    @Test("A layout needs a name, and names are unique")
    func layoutNames() {
        expect("\n[[layouts]]\ndisplays = [\"X\"]", line: 2, "layout needs a name")
        expect("[[layouts]]\nname = \"A\"\ndisplays = [\"X\"]\n[[layouts]]\nname = \"A\"\ndisplays = [\"Y\"]",
               line: 5, "layout name \"A\" is used twice")
    }

    @Test("A layout with displays present but empty is an error at displays")
    func emptyDisplays() {
        expect("[[layouts]]\nname = \"A\"\ndisplays = []", line: 3, "displays must list at least one display")
    }

    @Test("A layout with neither displays nor a shortcut is an error at its header")
    func layoutWithoutTrigger() {
        expect("[[layouts]]\nname = \"Desk\"", line: 1, "layout \"Desk\" needs displays or a shortcut")
        #expect(config("[[layouts]]\nname = \"Desk\"\nshortcut = \"ctrl+opt+cmd+1\"") != nil)
    }

    @Test("Two layouts on the same set of displays clash, in any order")
    func sameDisplaySet() {
        expect("[[layouts]]\nname = \"A\"\ndisplays = [\"X\", \"Y\"]\n[[layouts]]\nname = \"B\"\ndisplays = [\"Y\", \"X\"]",
               line: 6, "layouts \"A\" and \"B\" both claim the same displays")
        #expect(config("[[layouts]]\nname = \"A\"\ndisplays = [\"X\"]\n[[layouts]]\nname = \"B\"\ndisplays = [\"X\", \"Y\"]") != nil)
    }

    @Test("An entry needs an app and a place")
    func entryRequiredKeys() {
        expect("[[layouts]]\nname = \"A\"\ndisplays = [\"X\"]\n[[layouts.windows]]\nplace = \"maximize\"",
               line: 4, "each window entry needs an app")
        expect("[[layouts]]\nname = \"A\"\ndisplays = [\"X\"]\n[[layouts.windows]]\napp = \"a\"",
               line: 4, "each window entry needs a place")
    }

    @Test("An unknown placement is named at the place line")
    func unknownPlacement() {
        expect("[[layouts]]\nname = \"A\"\ndisplays = [\"X\"]\n[[layouts.windows]]\napp = \"a\"\nplace = \"middle\"",
               line: 6, "unknown placement \"middle\"")
    }

    @Test("Every NamedPlacement is a valid place")
    func everyPlacement() {
        for placement in NamedPlacement.allCases {
            let text = "[[layouts]]\nname = \"A\"\ndisplays = [\"X\"]\n[[layouts.windows]]\napp = \"a\"\nplace = \"\(placement.rawValue)\""
            #expect(config(text)?.layouts.first?.entries.first?.place == placement)
        }
    }

    @Test("An entry in a layout with several displays needs a display, at the entry's header")
    func entryNeedsDisplay() {
        expect("[[layouts]]\nname = \"A\"\ndisplays = [\"X\", \"Y\"]\n[[layouts.windows]]\napp = \"a\"\nplace = \"maximize\"",
               line: 4, "this entry needs a display, because layout \"A\" names more than one")
    }

    @Test("An entry's display must be one of its layout's displays")
    func entryDisplayOutside() {
        expect("[[layouts]]\nname = \"A\"\ndisplays = [\"X\"]\n[[layouts.windows]]\napp = \"a\"\nplace = \"maximize\"\ndisplay = \"Z\"",
               line: 7, "display \"Z\" isn't one of layout \"A\"'s displays")
        // A layout without displays has nothing to check against.
        #expect(config("[[layouts]]\nname = \"A\"\nshortcut = \"ctrl+opt+cmd+1\"\n[[layouts.windows]]\napp = \"a\"\nplace = \"maximize\"\ndisplay = \"Z\"") != nil)
    }

    @Test("Entries and layouts keep their file order and their error lines, across several of each")
    func severalLayouts() throws {
        let text = """
        [[layouts]]
        name = "A"
        displays = ["X"]
        [[layouts.windows]]
        app = "one"
        place = "left-half"
        [[layouts.windows]]
        app = "two"
        place = "right-half"

        [[layouts]]
        name = "B"
        displays = ["Y"]
        [[layouts.windows]]
        app = "three"
        place = "left-half"
        [[layouts.windows]]
        app = "four"
        place = "nowhere"
        """
        expect(text, line: 19, "unknown placement \"nowhere\"")
        let parsed = try #require(config(text.replacingOccurrences(of: "nowhere", with: "maximize")))
        #expect(parsed.layouts.map(\.name) == ["A", "B"])
        #expect(parsed.layouts[0].entries.map(\.app) == ["one", "two"])
        #expect(parsed.layouts[1].entries.map(\.app) == ["three", "four"])
    }

    @Test("Layouts written as inline tables are read too, and report their key's line")
    func inlineLayouts() {
        #expect(config("layouts = [{ name = \"A\", shortcut = \"ctrl+opt+cmd+1\" }]")?.layouts.count == 1)
        expect("\nlayouts = [{ name = \"A\" }]", line: 2, "layout \"A\" needs displays or a shortcut")
    }

    @Test("A section of the wrong shape is an error")
    func wrongShape() {
        expect("shortcuts = 3", line: 1, "\"shortcuts\" must be a table")
        expect("layouts = 3", line: 1, "\"layouts\" must be a list of tables")
        expect("[layouts]\nname = \"A\"", line: 1, "\"layouts\" must be a list of tables")
    }

    @Test("The first error in file order wins among top-level settings")
    func firstErrorWins() {
        expect("step = 0\ngap = 500", line: 1, "step must be between 1 and 500")
        expect("gap = 500\nstep = 0", line: 1, "gap must be between 0 and 100")
        expect("[shortcuts]\ncenter = \"hyper+c\"\n[[layouts]]\nname = \"A\"", line: 2, "unknown modifier \"hyper\"")
    }

    @Test("Sections are checked where they stand: a layout error above [shortcuts] wins over one below it")
    func sectionsInFileOrder() {
        let layout = "[[layouts]]\nname = \"A\"\ndisplays = [\"X\"]\n[[layouts.windows]]\napp = \"a\"\nplace = \"middle\"\n"
        expect(layout + "[shortcuts]\nbogus = \"ctrl+opt+c\"", line: 6, "unknown placement \"middle\"")
        expect("[shortcuts]\nbogus = \"ctrl+opt+c\"\n" + layout, line: 2, "unknown action \"bogus\"")
    }

    @Test("A chord clash is reported at the later of the two, whichever section comes first")
    func clashesInFileOrder() {
        let layout = "[[layouts]]\nname = \"A\"\nshortcut = \"ctrl+opt+cmd+1\"\n[[layouts.windows]]\napp = \"a\"\nplace = \"maximize\"\n"
        expect(layout + "[shortcuts]\ncenter = \"ctrl+opt+cmd+1\"", line: 8,
               "\"ctrl+opt+cmd+1\" is also used by layout \"A\"")
        let bad = layout.replacingOccurrences(of: "maximize", with: "middle")
        expect(bad + "[shortcuts]\ncenter = \"ctrl+opt+cmd+1\"", line: 6, "unknown placement \"middle\"")
        expect("[shortcuts]\ncenter = \"ctrl+opt+cmd+1\"\n" + layout, line: 5,
               "\"ctrl+opt+cmd+1\" is also used by center")
    }

    @Test("Keys inside a table are checked in file order, not in TOMLDecoder's order")
    func keysInFileOrder() {
        // TOMLTable lists values before arrays, so an unsorted walk would report the unknown key first.
        expect("[[layouts]]\nname = \"A\"\ndisplays = []\nbogus = 1", line: 3, "displays must list at least one display")
    }

    @Test("A bad escape inside a list of strings reports TOMLDecoder's text, not a type error")
    func badEscapeInList() throws {
        let failure = try #require(error("[[layouts]]\nname = \"A\"\ndisplays = [\"a\\qb\"]"))
        #expect(failure.line == 3)
        #expect(failure.message == "Illegal escape character 'q'.")
    }

    @Test("An empty or blank layout name counts as no name")
    func blankName() {
        expect("[[layouts]]\nname = \"\"\ndisplays = [\"X\"]", line: 1, "layout needs a name")
        expect("[[layouts]]\nname = \"  \"\ndisplays = [\"X\"]", line: 1, "layout needs a name")
    }

    @Test("A layout shortcut of \"none\" is refused, because a layout without one just leaves it out")
    func layoutShortcutNone() {
        expect("[[layouts]]\nname = \"A\"\ndisplays = [\"X\"]\nshortcut = \"none\"", line: 4,
               "layout shortcut can't be \"none\"; leave it out instead")
    }

    @Test("A leading byte order mark doesn't break the file")
    func byteOrderMark() {
        #expect(config("\u{FEFF}gap = 3")?.gap == 3)
        expect("\u{FEFF}gap = 3\ngapp = 1", line: 2, "unknown key \"gapp\"")
    }

    @Test("Interleaved files are checked in true file order, so the later claim or error is the one reported")
    func interleavedSections() {
        let head = "[[layouts]]\nname = \"A\"\ndisplays = [\"X\"]\n"
        // Q1: layout B's shortcut comes after center's, so B is the later claim.
        expect(head + "[shortcuts]\ncenter = \"ctrl+opt+cmd+1\"\n[[layouts]]\nname = \"B\"\nshortcut = \"ctrl+opt+cmd+1\"",
               line: 8, "\"ctrl+opt+cmd+1\" is also used by center")
        // Q2: the [shortcuts] error at line 5 precedes layout B's error at line 8.
        expect(head + "[shortcuts]\nbogus = \"x\"\n[[layouts]]\nname = \"B\"\ndisplays = []",
               line: 5, "unknown action \"bogus\"")
    }

    @Test("A default chord is freed by naming its action in [shortcuts], wherever that table sits")
    func rebindFreesDefault() {
        #expect(config("[shortcuts]\ncenter = \"ctrl+opt+left\"\nleft-half = \"ctrl+opt+shift+left\"") != nil)
        #expect(config("[[layouts]]\nname = \"A\"\nshortcut = \"ctrl+opt+left\"\n[shortcuts]\nleft-half = \"ctrl+opt+shift+left\"") != nil)
    }

    @Test("Layout names that differ only by surrounding whitespace are the same name")
    func trimmedNames() throws {
        expect("[[layouts]]\nname = \"A\"\ndisplays = [\"X\"]\n[[layouts]]\nname = \"A \"\ndisplays = [\"Y\"]",
               line: 5, "layout name \"A\" is used twice")
        #expect(try #require(config("[[layouts]]\nname = \" A \"\ndisplays = [\"X\"]")).layouts.first?.name == "A")
    }
}
