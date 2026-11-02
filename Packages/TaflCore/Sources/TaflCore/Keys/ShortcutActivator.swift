public enum HotkeyTarget: Hashable, Sendable {
    case action(Action)
    case layout(String)
}

public struct HotkeyRegistration: Hashable, Sendable {
    public let id: UInt32

    public init(id: UInt32) {
        self.id = id
    }
}

public protocol HotkeyRegistrar: AnyObject {
    /// Returns nil when the system refuses the chord, for example because another app holds it.
    func register(_ chord: KeyChord) -> HotkeyRegistration?
    func unregister(_ registration: HotkeyRegistration)
}

public enum ActivationFailure: Equatable, Sendable {
    case untranslatable(String)
    case taken
}

@MainActor
public final class ShortcutActivator {
    private let registrar: any HotkeyRegistrar
    private var targets: [HotkeyRegistration: HotkeyTarget] = [:]

    public init(registrar: any HotkeyRegistrar) {
        self.registrar = registrar
    }

    /// Replaces the whole registered set. Only the shortcuts that failed are returned.
    public func activate(_ config: Config, table: KeyboardLayoutTable) -> [HotkeyTarget: ActivationFailure] {
        deactivateAll()
        var failures: [HotkeyTarget: ActivationFailure] = [:]
        for action in Action.allCases {
            let chord: KeyChord
            switch config.binding(for: action) {
            case .unbound:
                continue
            case .standard:
                guard let standard = DefaultShortcuts.chords[action] else { continue }
                chord = standard
            case .custom(let shortcut):
                switch KeyTranslator.chord(for: shortcut, table: table) {
                case .success(let translated): chord = translated
                case .failure(let error):
                    failures[.action(action)] = .untranslatable(error.message)
                    continue
                }
            }
            register(chord, for: .action(action), failures: &failures)
        }
        for layout in config.layouts {
            guard let shortcut = layout.shortcut else { continue }
            let target = HotkeyTarget.layout(layout.name)
            switch KeyTranslator.chord(for: shortcut, table: table) {
            case .success(let chord): register(chord, for: target, failures: &failures)
            case .failure(let error): failures[target] = .untranslatable(error.message)
            }
        }
        return failures
    }

    public func target(for registration: HotkeyRegistration) -> HotkeyTarget? {
        targets[registration]
    }

    public func deactivateAll() {
        for registration in targets.keys { registrar.unregister(registration) }
        targets.removeAll()
    }

    private func register(_ chord: KeyChord, for target: HotkeyTarget,
                          failures: inout [HotkeyTarget: ActivationFailure]) {
        if let registration = registrar.register(chord) {
            targets[registration] = target
        } else {
            failures[target] = .taken
        }
    }
}
