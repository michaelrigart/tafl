import Testing
@testable import TaflCore

struct DisplayMatcherTests {
    private let builtIn = namedDisplay("Built-in Retina Display", rect(0, 0, 1512, 982), serial: 1)
    private let hdr = namedDisplay("LG HDR", rect(1512, 0, 3840, 2160), serial: 2)
    private let lg1 = namedDisplay("LG", rect(0, 0, 1000, 800), serial: 1)
    private let lg2 = namedDisplay("LG", rect(1000, 0, 1000, 800), serial: 2)

    @Test func matcherNamesAndIdentifiers() {
        #expect(DisplayMatcher.display(for: "LG HDR", in: [builtIn, hdr]) == hdr)
        #expect(DisplayMatcher.display(for: "LG", in: [lg1, lg2]) == nil)
        #expect(DisplayMatcher.display(for: "7789-30648-1", in: [lg1, lg2]) == lg1)
        #expect(DisplayMatcher.display(for: "7789-30648-2", in: [lg1, lg2]) == lg2)
        #expect(DisplayMatcher.display(for: "Missing", in: [lg1, lg2]) == nil)
    }

    @Test func claimsNeedEveryDisplayMatchedOnce() {
        let references = ["LG HDR", "Built-in Retina Display"]
        #expect(DisplayMatcher.claims(references, [builtIn, hdr]))
        #expect(!DisplayMatcher.claims(references, [builtIn, hdr, lg1]))
        #expect(!DisplayMatcher.claims(references, [builtIn]))
        #expect(!DisplayMatcher.claims(["LG HDR", "LG HDR"], [hdr, hdr]))
    }
}
