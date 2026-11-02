import Foundation

public struct Modifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = Modifiers(rawValue: 1 << 0)
    public static let option = Modifiers(rawValue: 1 << 1)
    public static let command = Modifiers(rawValue: 1 << 2)
    public static let shift = Modifiers(rawValue: 1 << 3)
}

public enum NamedKey: String, CaseIterable, Sendable {
    case left, right, down, up
    case `return`, delete, space, tab, escape

    public var keyCode: UInt16 {
        switch self {
        case .left: 123
        case .right: 124
        case .down: 125
        case .up: 126
        case .return: 36
        case .delete: 51
        case .space: 49
        case .tab: 48
        case .escape: 53
        }
    }
}

public enum ShortcutKey: Hashable, Sendable {
    case named(NamedKey)
    case character(String)
}

public enum ShortcutSyntaxError: Error, Equatable, Sendable {
    case empty
    case unknownModifier(String)
    case missingKey
    case missingPrimaryModifier
    case unknownKey(String)

    public var message: String {
        switch self {
        case .empty: "shortcut is empty"
        case .unknownModifier(let name): "unknown modifier \"\(name)\""
        case .missingKey: "shortcut needs a key"
        case .missingPrimaryModifier: "shortcut needs ctrl, opt or cmd"
        case .unknownKey(let name): "unknown key \"\(name)\""
        }
    }
}

public struct Shortcut: Hashable, Sendable {
    public let modifiers: Modifiers
    public let key: ShortcutKey

    public init(modifiers: Modifiers, key: ShortcutKey) {
        self.modifiers = modifiers
        self.key = key
    }

    private static let modifierNames: [String: Modifiers] = [
        "ctrl": .control, "control": .control,
        "opt": .option, "option": .option, "alt": .option,
        "cmd": .command, "command": .command,
        "shift": .shift,
    ]

    public static func parse(_ text: String) -> Result<Shortcut, ShortcutSyntaxError> {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .failure(.empty) }
        let parts = trimmed.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var modifiers: Modifiers = []
        for part in parts.dropLast() {
            guard let modifier = modifierNames[part.lowercased()] else { return .failure(.unknownModifier(part)) }
            modifiers.insert(modifier)
        }
        let last = parts[parts.count - 1]
        if last.isEmpty || modifierNames[last.lowercased()] != nil { return .failure(.missingKey) }
        let key: ShortcutKey
        if last.count == 1 {
            key = .character(last.lowercased())
        } else if let named = NamedKey(rawValue: last.lowercased()) {
            key = .named(named)
        } else {
            return .failure(.unknownKey(last))
        }
        guard !modifiers.isDisjoint(with: [.control, .option, .command]) else {
            return .failure(.missingPrimaryModifier)
        }
        return .success(Shortcut(modifiers: modifiers, key: key))
    }

    public var text: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.command) { parts.append("cmd") }
        if modifiers.contains(.shift) { parts.append("shift") }
        switch key {
        case .named(let named): parts.append(named.rawValue)
        case .character(let character): parts.append(character)
        }
        return parts.joined(separator: "+")
    }
}
