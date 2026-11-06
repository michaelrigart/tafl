import Foundation
import TaflCore

public struct Tiling27: Sendable {
    private let value: @Sendable (String) -> Any?

    /// `read` looks a key up; by default in Apple's `com.apple.WindowManager` domain, which Tafl only reads.
    public init(read value: @escaping @Sendable (String) -> Any? = { key in
        UserDefaults(suiteName: "com.apple.WindowManager")?.object(forKey: key)
    }) {
        self.value = value
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
        (value(key) as? NSNumber)?.boolValue
    }
}
