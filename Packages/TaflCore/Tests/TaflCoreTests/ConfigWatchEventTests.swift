import Foundation
import Testing
@testable import TaflCore

@Test func anAttributeOnlyEventDoesNotReload() {
    // open(O_TRUNC) posts attrib alone; the write that fills the file arrives as its own event.
    #expect(!ConfigWatchEvent.shouldReload(mask: .attrib))
}

@Test func anyContentOrNameEventReloads() {
    #expect(ConfigWatchEvent.shouldReload(mask: .write))
    #expect(ConfigWatchEvent.shouldReload(mask: .extend))
    #expect(ConfigWatchEvent.shouldReload(mask: .delete))
    #expect(ConfigWatchEvent.shouldReload(mask: .rename))
    #expect(ConfigWatchEvent.shouldReload(mask: .link))
    #expect(ConfigWatchEvent.shouldReload(mask: [.attrib, .write]))
}
