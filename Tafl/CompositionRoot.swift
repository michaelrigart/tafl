import AppKit
import TaflCore
import TaflPlatform27

/// Builds the app's parts and wires them together. It owns the Accessibility state and the
/// shortcut gate, the one place that registers hotkeys.
final class CompositionRoot {
    private let permission = Permission27()
    private let engine: WindowEngine
    private let registrar = CarbonHotkeyRegistrar()
    private let activator: ShortcutActivator
    private let overlay: FailureOverlay
    private let statusItem = StatusItemController()
    private var table: KeyboardLayoutTable
    private var watcher: ConfigWatcher?
    private var sessionEvents: SessionEvents?
    private var reportTask: Task<Void, Never>?
    private var permissionTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var shuttingDown = false
    private var startTask: Task<Void, Never>?
    private var activeLayout: String?
    /// Whether Accessibility was granted when last looked at.
    private var trusted = false
    private var engineStarted = false

    private lazy var onboarding = OnboardingWindow { [unowned self] in syncPermission() }
    private lazy var configController = ConfigController(
        path: Self.configPath,
        engine: engine,
        table: { [unowned self] in table },
        gate: { [unowned self] config in gate(config) },
        engineIsRunning: { [unowned self] in engineStarted })

    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let configPath = home.appendingPathComponent(".config/tafl/config.toml").path
    private static let memoryURL = home.appendingPathComponent(".local/state/tafl/memory.json")

    init() {
        let clock = SystemClock()
        engine = WindowEngine(
            platform: PlatformFactory.make(),
            store: MemoryStore(fileURL: Self.memoryURL),
            clock: clock,
            timing: .provisional,
            steps: [GapStep(), MinimumSizeStep(), OnScreenStep()],
            adjustments: MacOSAdjustment.measured27)
        activator = ShortcutActivator(registrar: registrar)
        overlay = FailureOverlay(clock: clock)
        table = KeyboardLayout27.table()
    }

    // MARK: Startup and quit

    /// Loads the config, and when Accessibility is granted starts the engine and the shortcuts,
    /// then shows the status item.
    func start() {
        registrar.onPress = { [unowned self] registration in hotkeyPressed(registration) }
        reportTask = Task { [engine] in
            for await report in engine.reports { handle(report) }
        }
        permissionTask = Task { [permission] in
            for await _ in permission.changes { syncPermission() }
        }
        configController.reload()
        let watcher = ConfigWatcher(path: Self.configPath) { [unowned self] in configController.reload() }
        watcher.start()
        self.watcher = watcher
        syncPermission()
        configController.onChange = { [unowned self] in refreshMenu() }
        configController.onEngineUpdated = { [unowned self] in await refreshActiveLayout() }
        statusItem.onApplyLayout = { [unowned self] name in
            Task { await engine.applyLayout(named: name) }
        }
        refreshMenu()
        let events = SessionEvents(
            onWake: { [unowned self] in resume(after: "wake") },
            onSessionActive: { [unowned self] in resume(after: "session active") },
            onWillSleep: { [unowned self] in Task { await engine.save() } },
            onInputSourceChanged: { [unowned self] in
                table = KeyboardLayout27.table()
                Log.config.notice("Input source changed")
                configController.reactivate()
            })
        events.start()
        sessionEvents = events
        Log.app.notice("Tafl started")
    }

    /// Removes the hotkeys, then stops the engine, which saves the memory. Windows stay where they
    /// are. The report consumer runs until the engine has stopped, so a failed save is logged.
    func shutdown() async {
        shuttingDown = true
        permissionTask?.cancel()
        watcher?.stop()
        sessionEvents?.stop()
        activator.deactivateAll()
        await startTask?.value
        await restartTask?.value
        activator.deactivateAll()
        if engineStarted { await engine.stop() }
        await Task.yield()
        reportTask?.cancel()
        Log.app.notice("Tafl quit")
    }

    /// The app was opened again from Finder or Spotlight.
    func reopen() {
        if !trusted {
            onboarding.show()
        } else {
            Log.ui.notice("Reopened; Settings is not available yet")
        }
    }

    // MARK: Accessibility

    /// Reads the Accessibility grant and acts on a change: starts the engine, or on a regain
    /// restarts observing and activates the shortcuts, or on a loss removes them.
    func syncPermission() {
        let granted = permission.isTrusted
        let regained = granted && !trusted
        trusted = granted
        defer { refreshMenu() }
        guard granted else {
            configController.reactivate()
            onboarding.show()
            return
        }
        onboarding.close()
        if !engineStarted {
            startEngine()
        } else if regained {
            Log.app.notice("Accessibility granted again")
            configController.reactivate()
            restartObserving()
        }
    }

    private func permissionLost() {
        Log.app.notice("Accessibility permission missing")
        trusted = false
        configController.reactivate()
        onboarding.show()
    }

    private func startEngine() {
        guard startTask == nil else { return }
        let config = configController.config
        startTask = Task {
            await engine.start(config: config)
            engineStarted = true
            if configController.config != config { configController.pushToEngine() }
            configController.reactivate()
            await refreshActiveLayout()
        }
    }

    // MARK: Shortcuts

    /// The only caller of `activate`: shortcuts exist only while Accessibility is granted and the
    /// engine is running.
    private func gate(_ config: Config) -> [HotkeyTarget: ActivationFailure] {
        guard engineStarted, trusted, !shuttingDown, permission.isTrusted else {
            activator.deactivateAll()
            return [:]
        }
        return activator.activate(config, table: table)
    }

    private func hotkeyPressed(_ registration: HotkeyRegistration) {
        guard let target = activator.target(for: registration) else { return }
        switch target {
        case .action(let action):
            Log.engine.notice("Action \(action.rawValue, privacy: .public)")
            Task { await engine.perform(action) }
        case .layout(let name):
            Log.engine.notice("Layout shortcut \(name, privacy: .private)")
            Task { await engine.applyLayout(named: name) }
        }
    }

    /// Restarts run one after another, never side by side.
    private func restartObserving() {
        let previous = restartTask
        restartTask = Task {
            await previous?.value
            await engine.restartObserving()
        }
    }

    private func resume(after moment: String) {
        Log.app.notice("Resuming after \(moment, privacy: .public)")
        configController.reactivate()
        guard engineStarted, trusted else { return }
        restartObserving()
    }

    // MARK: Reports and menu

    private func handle(_ report: EngineReport) {
        switch report {
        case .failure(let kind, let display):
            Log.engine.notice("Failure \(kind.category, privacy: .public)")
            overlay.show(kind, on: display)
            if kind == .permissionMissing { permissionLost() }
        case .layoutApplied(let name, let placed, let failed):
            Log.engine.notice("Layout \(name, privacy: .private) applied, placed \(placed, privacy: .public), failed \(failed, privacy: .public)")
            Task { await refreshActiveLayout() }
        case .displayChangeHandled(let moved):
            Log.engine.notice("Display change handled, moved \(moved, privacy: .public)")
            Task { await refreshActiveLayout() }
        case .unobservable(let bundleID):
            Log.engine.notice("Cannot observe \(bundleID ?? "an app", privacy: .public)")
        case .memory(let load):
            Log.engine.notice("Window memory \(Self.describe(load), privacy: .public)")
        case .memorySaveFailed:
            Log.engine.notice("Window memory could not be saved")
        }
    }

    private static func describe(_ load: MemoryLoad) -> String {
        switch load {
        case .fresh: "fresh"
        case .loaded: "loaded"
        case .recoveredFromCorrupt: "recovered from a corrupt file"
        case .refused(let version): "refused, file version \(version)"
        case .unavailable: "unavailable"
        }
    }

    private func refreshActiveLayout() async {
        activeLayout = await engine.activeLayoutName
        refreshMenu()
    }

    private func refreshMenu() {
        let config = configController.config
        var issues = ConfigIssueLines.lines(
            status: configController.state.status, failures: configController.activationFailures,
            layouts: config.layouts)
        if !trusted { issues.insert("Accessibility permission is needed", at: 0) }
        statusItem.content = StatusMenuContent(
            visible: config.menuBarIcon,
            layouts: config.layouts.map(\.name),
            activeLayout: activeLayout,
            issues: issues,
            canApplyLayouts: engineStarted && trusted)
    }
}
