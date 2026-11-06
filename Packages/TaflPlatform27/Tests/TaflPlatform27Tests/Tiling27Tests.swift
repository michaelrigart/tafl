import Foundation
import Testing
@testable import TaflPlatform27

/// Values are stored as `Any` so a test can supply an integer, as macOS stores them, or a Bool.
private func tilingReading(_ values: [String: Any]) -> Tiling27 {
    nonisolated(unsafe) let values = values // reason: read-only test fixture
    return Tiling27(read: { values[$0] })
}

@Test func edgeDragStoredAsIntegerZeroReadsAsOff() {
    let tiling = tilingReading(["EnableTilingByEdgeDrag": 0])
    #expect(tiling.read().edgeDrag == false)
}

@Test func edgeDragStoredAsTrueReadsAsOn() {
    let tiling = tilingReading(["EnableTilingByEdgeDrag": true])
    #expect(tiling.read().edgeDrag == true)
}

@Test func eachSettingReadsItsOwnKey() {
    let keys: [String: Any] = [
        "EnableTilingByEdgeDrag": 0,
        "EnableTilingOptionAccelerator": 1,
        "EnableTopTilingByEdgeDrag": true,
        "EnableTiledWindowMargins": true,
    ]
    let tiling = tilingReading(keys)
    let settings = tiling.read()
    #expect(settings.edgeDrag == false)
    #expect(settings.optionAccelerator == true)
    #expect(settings.topEdgeDrag == true)
    #expect(settings.tiledMargins == true)
}

@Test func unsetSwitchesReadAsNil() {
    let tiling = tilingReading([:])
    #expect(tiling.read()
        == .init(edgeDrag: nil, optionAccelerator: nil, topEdgeDrag: nil, tiledMargins: nil))
}

@Test func oneUnsetKeyDoesNotAffectTheOthers() {
    let tiling = tilingReading(["EnableTilingByEdgeDrag": 1])
    let settings = tiling.read()
    #expect(settings.edgeDrag == true)
    #expect(settings.optionAccelerator == nil)
}

@Test func missingDefaultsReadAsAllNil() {
    #expect(Tiling27(read: { _ in nil }).read() == .init(edgeDrag: nil, optionAccelerator: nil, topEdgeDrag: nil, tiledMargins: nil))
    #expect(Tiling27(defaults: nil).read() == .init(edgeDrag: nil, optionAccelerator: nil, topEdgeDrag: nil, tiledMargins: nil))
}

/// A defaults object that answers from a dictionary: it registers nothing process-wide and touches no disk.
private final class StubDefaults: UserDefaults {
    private let values: [String: Any]

    init?(_ values: [String: Any]) {
        self.values = values
        super.init(suiteName: nil)
    }

    override func object(forKey defaultName: String) -> Any? {
        values[defaultName]
    }
}

@Test func everySettingIsReadFromTheOneDefaultsObjectGiven() throws {
    let defaults = try #require(StubDefaults(["EnableTilingByEdgeDrag": 0, "EnableTiledWindowMargins": true]))
    let settings = Tiling27(defaults: defaults).read()
    #expect(settings == .init(edgeDrag: false, optionAccelerator: nil, topEdgeDrag: nil, tiledMargins: true))
}
