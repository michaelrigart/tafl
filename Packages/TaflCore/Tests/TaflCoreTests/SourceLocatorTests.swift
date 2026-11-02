import Testing
@testable import TaflCore

@Suite("Source locator")
struct SourceLocatorTests {
    @Test("Nested paths find their line across several tables and arrays of tables")
    func locatorFindsNestedPaths() {
        let text = """
        gap = 2

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

          [[layouts.windows]]
          app = "three"
          place = "maximize"

          [[layouts.windows]]
          app = "four"
          place = "top-half"
        """
        let locator = SourceLocator(text)
        #expect(locator.line(of: [.key("gap")]) == 1)
        #expect(locator.line(of: [.key("layouts")]) == 3)
        #expect(locator.line(of: [.key("layouts"), .index(0)]) == 3)
        #expect(locator.line(of: [.key("layouts"), .index(0), .key("displays")]) == 5)
        #expect(locator.line(of: [.key("layouts"), .index(0), .key("windows"), .index(1)]) == 11)
        #expect(locator.line(of: [.key("layouts"), .index(0), .key("windows"), .index(1), .key("place")]) == 13)
        #expect(locator.line(of: [.key("layouts"), .index(1)]) == 15)
        #expect(locator.line(of: [.key("layouts"), .index(1), .key("windows"), .index(0), .key("place")]) == 20)
        #expect(locator.line(of: [.key("layouts"), .index(1), .key("windows"), .index(1), .key("place")]) == 24)
        #expect(locator.line(of: [.key("layouts"), .index(2)]) == nil)
    }

    @Test("Plain tables, dotted keys and quoted keys are found by their parts")
    func tablesAndKeys() {
        let text = """
        [shortcuts]
        left-half = "none"
        "center" = "none"
        'maximize' = "none"
        [other.deep]
        a.b = 1
        """
        let locator = SourceLocator(text)
        #expect(locator.line(of: [.key("shortcuts")]) == 1)
        #expect(locator.line(of: [.key("shortcuts"), .key("left-half")]) == 2)
        #expect(locator.line(of: [.key("shortcuts"), .key("center")]) == 3)
        #expect(locator.line(of: [.key("shortcuts"), .key("maximize")]) == 4)
        #expect(locator.line(of: [.key("other"), .key("deep")]) == 5)
        #expect(locator.line(of: [.key("other"), .key("deep"), .key("a")]) == 6)
        #expect(locator.line(of: [.key("other"), .key("deep"), .key("a"), .key("b")]) == 6)
    }

    @Test("A header with spaces and a quoted part is still found")
    func spacedHeaders() {
        let locator = SourceLocator("[ a . \"b c\" ]\nk = 1")
        #expect(locator.line(of: [.key("a"), .key("b c"), .key("k")]) == 2)
    }

    @Test("Comments and the insides of multi-line strings and arrays don't count as keys or headers")
    func skipsCommentsAndStrings() {
        let text = """
        # [[layouts]]
        a = \"\"\"
        [[layouts]]
        fake = 1
        \"\"\"
        b = '''
        [shortcuts]
        '''
        list = [
          "x = 1",   # [nope]
          "y",
        ]
        c = "has # hash and [bracket]"
        [real]
        d = 1
        """
        let locator = SourceLocator(text)
        #expect(locator.line(of: [.key("layouts")]) == nil)
        #expect(locator.line(of: [.key("fake")]) == nil)
        #expect(locator.line(of: [.key("shortcuts")]) == nil)
        #expect(locator.line(of: [.key("b")]) == 6)
        #expect(locator.line(of: [.key("list")]) == 9)
        #expect(locator.line(of: [.key("c")]) == 13)
        #expect(locator.line(of: [.key("real")]) == 14)
        #expect(locator.line(of: [.key("real"), .key("d")]) == 15)
    }

    @Test("Windows line endings count lines the same way")
    func carriageReturns() {
        let locator = SourceLocator("a = 1\r\n[[x]]\r\nb = 2\r\n")
        #expect(locator.line(of: [.key("x"), .index(0), .key("b")]) == 3)
    }

    @Test("Garbage lines don't stall the scan")
    func garbage() {
        let locator = SourceLocator("= 1\n}\n]\nk = 1")
        #expect(locator.line(of: [.key("k")]) == 4)
    }
}
