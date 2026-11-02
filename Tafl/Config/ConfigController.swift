import Foundation
import TaflCore
import TaflPlatform27

/// Reads the config file and applies it: the state first, then the engine, the shortcut gate and
/// the login item. A file that does not parse leaves the last good configuration in force.
final class ConfigController {
    typealias Gate = (Config) -> [HotkeyTarget: ActivationFailure]

    var onChange: (() -> Void)?

    private(set) var state = ConfigState()
    private(set) var activationFailures: [HotkeyTarget: ActivationFailure] = [:]

    private let path: String
    private let engine: WindowEngine
    private let table: () -> KeyboardLayoutTable
    private let gate: Gate
    private let engineIsRunning: () -> Bool
    private var engineUpdate: Task<Void, Never>?

    var config: Config { state.effective }

    init(
        path: String,
        engine: WindowEngine,
        table: @escaping () -> KeyboardLayoutTable,
        gate: @escaping Gate,
        engineIsRunning: @escaping () -> Bool
    ) {
        self.path = path
        self.engine = engine
        self.table = table
        self.gate = gate
        self.engineIsRunning = engineIsRunning
    }

    func reload() {
        state.apply(ConfigFileReader.read(path: path), table: table())
        switch state.status {
        case .defaults: Log.config.notice("Config reloaded: no file, using defaults")
        case .loaded: Log.config.notice("Config reloaded")
        case .rejected(let error):
            Log.config.notice("Config rejected at line \(error.line ?? 0, privacy: .public): \(error.message, privacy: .private)")
        }
        pushToEngine()
        LoginItem.apply(state.effective.launchAtLogin)
        reactivate()
    }

    /// Sends the engine the configuration in force; the root calls it once the engine has started.
    func pushToEngine() {
        guard engineIsRunning() else { return }
        let config = state.effective
        let engine = engine
        let previous = engineUpdate
        engineUpdate = Task {
            await previous?.value
            await engine.update(config: config)
        }
    }

    /// Goes through the shortcut gate again with the configuration already read.
    func reactivate() {
        activationFailures = gate(state.effective)
        for (target, failure) in activationFailures {
            let reason = Self.reason(failure)
            switch target {
            case .action(let action):
                Log.config.notice("Shortcut not registered: \(action.rawValue, privacy: .public), \(reason, privacy: .public)")
            case .layout(let name):
                Log.config.notice("Shortcut not registered: layout \(name, privacy: .private), \(reason, privacy: .public)")
            }
        }
        onChange?()
    }

    private static func reason(_ failure: ActivationFailure) -> String {
        switch failure {
        case .untranslatable: "not on the keyboard layout"
        case .taken: "taken"
        case .clashes: "clashes with another shortcut"
        }
    }
}
