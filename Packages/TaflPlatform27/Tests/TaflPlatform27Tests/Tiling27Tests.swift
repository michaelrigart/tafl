import Foundation
import Testing
@testable import TaflPlatform27

private func withSuite(_ values: [String: Bool], _ body: (UserDefaults) -> Void) {
    let name = "com.michaelrigart.tafl.tests.tiling.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    for (key, value) in values { defaults.set(value, forKey: key) }
    body(defaults)
}

@Test func edgeDragSetToZeroReadsAsOff() {
    withSuite(["EnableTilingByEdgeDrag": false]) { defaults in
        #expect(Tiling27(defaults: defaults).read().edgeDrag == false)
    }
}

@Test func eachSettingReadsItsOwnKey() {
    let keys = [
        "EnableTilingByEdgeDrag": false,
        "EnableTilingOptionAccelerator": true,
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

@Test func unsetMarginsAreNilNotFalse() {
    withSuite([:]) { defaults in
        #expect(Tiling27(defaults: defaults).read().tiledMargins == nil)
    }
}

@Test func unsetSwitchesReadAsOff() {
    withSuite([:]) { defaults in
        let settings = Tiling27(defaults: defaults).read()
        #expect(settings.edgeDrag == false)
        #expect(settings.optionAccelerator == false)
        #expect(settings.topEdgeDrag == false)
    }
}

@Test func missingDefaultsReadAsAllOff() {
    #expect(Tiling27(defaults: nil).read() == .init(edgeDrag: false, optionAccelerator: false, topEdgeDrag: false, tiledMargins: nil))
}

@Test func readingNeverWritesTheDomain() {
    withSuite([:]) { defaults in
        _ = Tiling27(defaults: defaults).read()
        #expect(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("Enable") }.isEmpty)
    }
}
