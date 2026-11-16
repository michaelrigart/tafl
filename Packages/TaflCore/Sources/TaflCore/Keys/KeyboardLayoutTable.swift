import Foundation

public struct KeyChord: Hashable, Sendable {
    public let keyCode: UInt16
    public let modifiers: Modifiers

    public init(keyCode: UInt16, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public struct KeyOutputs: Equatable, Sendable {
    public let plain: String
    public let shifted: String

    public init(plain: String, shifted: String) {
        self.plain = plain
        self.shifted = shifted
    }
}

/// What the current keyboard layout prints on each key position, without and with Shift.
public struct KeyboardLayoutTable: Equatable, Sendable {
    public let outputs: [UInt16: KeyOutputs]

    public init(_ outputs: [UInt16: KeyOutputs]) {
        self.outputs = outputs
    }
}
