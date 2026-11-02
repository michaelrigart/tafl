import Foundation
import Testing
@testable import TaflPlatform27

/// Values are stored as `Any` so a test can write an integer, as macOS does, or a Bool.
private func withSuite(_ values: [String: Any], _ body: (UserDefaults) -> Void) {
    let name = "com.michaelrigart.tafl.tests.tiling.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    for (key, value) in values { defaults.set(value, forKey: key) }
    body(defaults)
}

@Test func edgeDragStoredAsIntegerZeroReadsAsOff() {
    withSuite(["EnableTilingByEdgeDrag": 0]) { defaults in
        #expect(Tiling27(defaults: defaults).read().edgeDrag == false)
    }
}

@Test func edgeDragStoredAsTrueReadsAsOn() {
    withSuite(["EnableTilingByEdgeDrag": true]) { defaults in
        #expect(Tiling27(defaults: defaults).read().edgeDrag == true)
    }
}

@Test func eachSettingReadsItsOwnKey() {
    let keys: [String: Any] = [
        "EnableTilingByEdgeDrag": 0,
        "EnableTilingOptionAccelerator": 1,
        "EnableTopTilingByEdgeDrag": true,
        "EnableTiledWindowMargins": true,
    ]
    withSuite(keys) { defaults in
        let settings = Tiling27(defaults: defaults).read()
        #expect(settings.edgeDrag == false)
        #expect(settings.optionAccelerator == true)
        #expect(settings.topEdgeDrag == true)
        #expect(settings.tiledMargins == true)
    }
}

@Test func unsetSwitchesReadAsNil() {
    withSuite([:]) { defaults in
        #expect(Tiling27(defaults: defaults).read()
            == .init(edgeDrag: nil, optionAccelerator: nil, topEdgeDrag: nil, tiledMargins: nil))
    }
}

@Test func oneUnsetKeyDoesNotAffectTheOthers() {
    withSuite(["EnableTilingByEdgeDrag": 1]) { defaults in
        let settings = Tiling27(defaults: defaults).read()
        #expect(settings.edgeDrag == true)
        #expect(settings.optionAccelerator == nil)
    }
}

@Test func missingDefaultsReadAsAllNil() {
    #expect(Tiling27(defaults: nil).read() == .init(edgeDrag: nil, optionAccelerator: nil, topEdgeDrag: nil, tiledMargins: nil))
}

@Test func readingNeverWritesTheDomain() {
    withSuite([:]) { defaults in
        _ = Tiling27(defaults: defaults).read()
        #expect(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("Enable") }.isEmpty)
    }
}
