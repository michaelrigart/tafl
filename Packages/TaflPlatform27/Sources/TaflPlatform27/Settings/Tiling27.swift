import Foundation
import TaflCore

public struct Tiling27: @unchecked Sendable { // reason: UserDefaults is thread-safe and this only reads it
    private let defaults: UserDefaults?

    public init(defaults: UserDefaults? = UserDefaults(suiteName: "com.apple.WindowManager")) {
        self.defaults = defaults
    }

    /// A setting whose key is unset is nil.
    public func read() -> TilingSettings {
        TilingSettings(
            edgeDrag: flag("EnableTilingByEdgeDrag"),
            optionAccelerator: flag("EnableTilingOptionAccelerator"),
            topEdgeDrag: flag("EnableTopTilingByEdgeDrag"),
            tiledMargins: flag("EnableTiledWindowMargins"))
    }

    private func flag(_ key: String) -> Bool? {
        (defaults?.object(forKey: key) as? NSNumber)?.boolValue
    }
}
