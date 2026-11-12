import Foundation
import TaflCore
import TaflPlatform27

/// Reads the config file and applies it: the state first, then the engine, the shortcut gate and
/// the login item. A file that does not parse leaves the last good configuration in force.
final class ConfigController {
    typealias Gate = (Config) -> [HotkeyTarget: ActivationFailure]

    var onChange: (() -> Void)?
    /// Called after each update the engine has taken, so the menu can ask which layout is active.
    var onEngineUpdated: (() async -> Void)?

    private(set) var state = ConfigState()
    private(set) var activationFailures: [HotkeyTarget: ActivationFailure] = [:]

    private let path: String
    private let engine: WindowEngine
    private let table: () -> KeyboardLayoutTable
    private let gate: Gate
    private let engineIsRunning: () -> Bool
    private var engineUpdate: Task<Void, Never>?
    private var lastRead: ConfigRead?
    private var loginItemApplied: Bool?

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
        let read = ConfigFileReader.read(path: path)
        switch ConfigReload.step(previous: lastRead, new: read, hasActivationFailures: !activationFailures.isEmpty) {
        case .nothing:
            return
        case .retryShortcuts:
            Log.config.notice("Config unchanged, trying the failed shortcuts again")
            reactivate()
            return
        case .apply:
            apply(read)
        }
    }

    /// The keyboard layout changed: parse the last read again against the new table, so a config
    /// that was invalid under the old layout, or is under the new one, is judged again. The file is
    /// not read anew: it may be in the middle of a save.
    func reparse() {
        switch ConfigReload.reparse(lastRead: lastRead) {
        case .read: reload()
        case .parse(let read): apply(read)
        }
    }

    private func apply(_ read: ConfigRead) {
        lastRead = read
        state.apply(read, table: table())
        switch state.status {
        case .defaults: Log.config.notice("Config reloaded: no file, using defaults")
        case .loaded: Log.config.notice("Config reloaded")
        case .rejected(let error):
            if let line = error.line {
                Log.config.notice("Config rejected at line \(line, privacy: .public): \(error.message, privacy: .private)")
            } else {
                Log.config.notice("Config rejected: \(error.message, privacy: .private)")
            }
        }
        pushToEngine()
        applyLoginItem()
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
            await onEngineUpdated?()
        }
    }

    private func applyLoginItem() {
        let enabled = state.effective.launchAtLogin
        switch ConfigReload.loginItem(enabled: enabled, lastApplied: loginItemApplied, bundlePath: Bundle.main.bundleURL.path) {
        case .unchanged: return
        case .apply: LoginItem.apply(enabled)
        case .skipNotInstalled: Log.app.notice("Launch at login left alone: this copy is not in /Applications")
        }
        loginItemApplied = enabled
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
