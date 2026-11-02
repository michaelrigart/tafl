import Foundation
import TaflCore

public struct Tiling27: @unchecked Sendable { // reason: UserDefaults is thread-safe and this only reads it
    private let defaults: UserDefaults?

    public init(defaults: UserDefaults? = UserDefaults(suiteName: "com.apple.WindowManager")) {
        self.defaults = defaults
    }

    /// A switch that is unset reads as off; only the margins setting keeps "unset" apart.
    public func read() -> TilingSettings {
        TilingSettings(
            edgeDrag: flag("EnableTilingByEdgeDrag") ?? false,
            optionAccelerator: flag("EnableTilingOptionAccelerator") ?? false,
            topEdgeDrag: flag("EnableTopTilingByEdgeDrag") ?? false,
            tiledMargins: flag("EnableTiledWindowMargins"))
    }

    private func flag(_ key: String) -> Bool? {
        (defaults?.object(forKey: key) as? NSNumber)?.boolValue
    }
}
