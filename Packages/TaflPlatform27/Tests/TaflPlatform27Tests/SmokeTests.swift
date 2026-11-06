import Testing
import TaflCore
@testable import TaflPlatform27

@Test func linksCore() {
    #expect(TaflCore.bundleID.hasSuffix("tafl"))
}
