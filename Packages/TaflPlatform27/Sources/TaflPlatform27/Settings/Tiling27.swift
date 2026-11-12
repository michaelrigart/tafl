import Foundation
import TaflCore

public struct Tiling27: Sendable {
    private let value: @Sendable (String) -> Any?

    /// Reads one defaults object, opened once; by default Apple's `com.apple.WindowManager` domain,
    /// which Tafl only reads.
    public init(defaults: UserDefaults? = UserDefaults(suiteName: "com.apple.WindowManager")) {
        nonisolated(unsafe) let defaults = defaults // reason: UserDefaults is documented as thread-safe
        self.init(read: { defaults?.object(forKey: $0) })
    }

    /// `read` looks a key up.
    public init(read value: @escaping @Sendable (String) -> Any?) {
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
