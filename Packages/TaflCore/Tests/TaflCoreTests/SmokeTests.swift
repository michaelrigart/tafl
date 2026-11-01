import Testing
import TOMLDecoder
@testable import TaflCore

@Test func bundleIdentifier() {
    #expect(TaflCore.bundleID == "com.michaelrigart.tafl")
}

@Test func tomlDecoderLinks() throws {
    #expect(try TOMLTable(source: "a = 1").keys == ["a"])
}
