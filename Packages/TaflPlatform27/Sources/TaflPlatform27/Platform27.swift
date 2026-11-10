import AppKit
import ApplicationServices
import Synchronization
import TaflCore

/// Tafl's view of macOS 27: windows through Accessibility, displays, the pointer, tiling settings and
/// the permission.
final class Platform27: WindowPlatform {
    let events: AsyncStream<PlatformEvent>
    private let eventContinuation: AsyncStream<PlatformEvent>.Continuation
    private let axQueue = AXQueue()
    private let registry = WindowRegistry()
    private let leases = WriteLeases()
    private let notices = NoticeRelay()
    private let catalog: WindowCatalog27
    private let observation: WindowObservation27
    private let watcher = Mutex<WorkspaceWatcher27?>(nil)
    /// Lives as long as the platform, so no reconfiguration callback is lost while observing restarts.
    private let reconfiguration: ReconfigurationMonitor27

    /// The grant as the app last found it: the engine's gates and the app read one value, and an action
    /// never runs a check of its own.
    private let accessibilityGranted: @Sendable () -> Bool

    init(accessibilityGranted: @escaping @Sendable () -> Bool) {
        self.accessibilityGranted = accessibilityGranted
        let (stream, continuation) = AsyncStream<PlatformEvent>.makeStream(bufferingPolicy: .unbounded)
        events = stream
        eventContinuation = continuation
        catalog = WindowCatalog27(registry: registry, axQueue: axQueue)
        observation = WindowObservation27(
            axQueue: axQueue, registry: registry, catalog: catalog, events: continuation, notices: notices
        )
        reconfiguration = ReconfigurationMonitor27 { phase, _ in
            continuation.yield(phase == .began ? .reconfigurationBegan : .reconfigurationEnded)
        }
    }

    // MARK: Displays, settings, permission

    func displays() async -> [Display] {
        await Displays27.current(axQueue: axQueue)
    }

    /// Located against the displays' own frames: the pointer needs no Dock read.
    func pointerDisplay() async -> DisplayIdentity? {
        let raw = await MainActor.run(body: DisplayReader27.displays)
        return Pointer27.display(in: Displays27.displays(from: raw, dock: nil))
    }

    func tilingSettings() async -> TilingSettings {
        Tiling27().read()
    }

    func isAccessibilityGranted() async -> Bool {
        accessibilityGranted()
    }

    func appName(pid: Int32) async -> String? {
        NSRunningApplication(processIdentifier: pid)?.localizedName
    }

    func launchDates(of pids: Set<Int32>) async -> [Int32: Date] {
        var dates: [Int32: Date] = [:]
        for pid in pids {
            if let date = NSRunningApplication(processIdentifier: pid)?.launchDate { dates[pid] = date }
        }
        return dates
    }

    func capabilities() async -> [CapabilityState] {
        let symbol = WindowIDResolver.privateSymbolAvailable
        let list = symbol || !WindowIDResolver.windowList().isEmpty
        return [Self.windowIdentityCapability(privateSymbol: symbol, windowList: list)]
    }

    static func windowIdentityCapability(privateSymbol: Bool, windowList: Bool) -> CapabilityState {
        let name = "Window identity"
        if privateSymbol {
            return CapabilityState(name: name, isAvailable: true, note: "Window ids come from macOS.")
        }
        if windowList {
            return CapabilityState(
                name: name, isAvailable: true,
                note: "Window ids are matched through the window list, so two windows of one app with the same frame can be mistaken for each other.")
        }
        return CapabilityState(name: name, isAvailable: false, note: "Window ids cannot be resolved, so windows are tracked without stable ids.")
    }

    // MARK: Windows

    /// Any window element the front-window lookup finds, dialogs and palettes included. It is
    /// registered and handed to `take` inside the read, on the app's queue.
    func focusedWindow<T: Sendable>(take: @escaping @Sendable (WindowSnapshot) -> T) async -> Result<T, PlatformFailure> {
        guard let app = await MainActor.run(body: AppInfo27.frontmost) else { return .failure(.noWindow) }
        let pid = app.pid
        Task { [observation] in await observation.discover(app) }
        let catalog = catalog
        let read = await axQueue.run(pid: pid) { () -> Result<T, AXFailure> in
            let found: Result<ElementRead, AXFailure> = switch AXWindowAccess.findFocusedWindow(of: pid) {
            case .failure(let failure): .failure(failure)
            case .success(let element): Windows27.read(element, pid: pid, resolveID: true)
            }
            return found.map { take(catalog.register($0, app: app).snapshot) }
        }
        return read.mapError { Windows27.failure(for: $0.code) }
    }

    func visibleWindows<T: Sendable>(take: @escaping @Sendable (WindowSnapshot) -> T) async -> [T] {
        let apps = await MainActor.run(body: AppInfo27.regularApps)
        return await withTaskGroup(of: (Int, [T]).self) { group in
            for (index, app) in apps.enumerated() {
                group.addTask {
                    await self.observation.discover(app)
                    return (index, await self.catalog.windows(of: app) { take($0.snapshot) })
                }
            }
            var parts: [(Int, [T])] = []
            for await part in group { parts.append(part) }
            return parts.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
    }

    /// Hands the snapshot to `take` inside the read, on the app's queue.
    func snapshot<T: Sendable>(
        of handle: WindowHandle,
        take: @escaping @Sendable (WindowSnapshot) -> T
    ) async -> Result<T, PlatformFailure> {
        guard let app = AppInfo27.running(pid: handle.pid) else { return .failure(.noWindow) }
        let pid = handle.pid
        let axQueue = axQueue
        let read = await Self.readRegistered(handle, registry: registry) { element in
            await axQueue.run(pid: pid) {
                Windows27.read(element.element, pid: pid, resolveID: false).map {
                    take(Windows27.snapshot(handle: handle, app: app, attributes: $0.attributes))
                }
            }
        }
        return read?.mapError { Windows27.failure(for: $0.code) } ?? .failure(.noWindow)
    }

    /// Reads the element registered for `handle`, or nil when none is. A read that fails, an invalid
    /// element included, fails only itself and keeps the registration: Accessibility answers "invalid"
    /// for live windows for about 2 s around a wake. Only the window's destroyed notification and its
    /// app's quit end a window (`WindowEnds`, `WindowObservation27.appQuit`).
    static func readRegistered<T: Sendable>(
        _ handle: WindowHandle,
        registry: WindowRegistry,
        read: (AXElementBox) async -> Result<T, AXFailure>
    ) async -> Result<T, AXFailure>? {
        guard let element = registry.element(for: handle) else { return nil }
        return await read(element)
    }

    /// One window after another, each on its app's queue, so the last ends on top. A window that is
    /// not registered, or that cannot be raised, is logged and skipped. `admit` is asked on the app's
    /// queue immediately before each raise and each frontmost write, and before the activation
    /// fallback; once it answers false nothing more is raised.
    func raise(_ windows: [WindowHandle], admit: @escaping @Sendable () -> Bool) async {
        for handle in windows {
            guard admit() else { return }
            guard let element = registry.element(for: handle) else {
                PlatformLog.windows.notice("Raise skipped: the window is not registered")
                continue
            }
            let pid = handle.pid
            let outcome = await axQueue.run(pid: pid) {
                Raise27.bringForward(
                    admit: admit,
                    raise: { AXWindowAccess.raise(element.element) },
                    makeFrontmost: { AXWindowAccess.setFrontmost(app: pid) })
            }
            switch outcome {
            case .raised: break
            case .stopped: return
            case .raisedWithoutFrontmost:
                PlatformLog.windows.notice("Raise: the app refused to come forward, activating it")
                if !(await Raise27.activate(pid: pid, admit: admit)) { return }
            case .failed(let code):
                PlatformLog.windows.notice("Raise failed, Accessibility error \(code.rawValue, privacy: .private)")
            }
        }
    }

    func beginWriting(_ handle: WindowHandle) async -> Result<any WriteSession, PlatformFailure> {
        guard let element = registry.element(for: handle), let app = AppInfo27.running(pid: handle.pid) else {
            return .failure(.noWindow)
        }
        let assistiveTechnologyOn = await MainActor.run {
            NSWorkspace.shared.isVoiceOverEnabled || NSWorkspace.shared.isSwitchControlEnabled
        }
        let session = await WriteSession27.begin(
            element: element, app: app, assistiveTechnologyOn: assistiveTechnologyOn, axQueue: axQueue, leases: leases)
        return .success(session)
    }

    // MARK: Observing

    func startObserving(notices: any WindowNotices) async -> [UnobservableApp] {
        self.notices.relay(to: notices)
        observation.end()
        observation.begin()
        let observation = observation
        let installed = await MainActor.run {
            let created = WorkspaceWatcher27()
            created.start(observation: observation)
            return created
        }
        let previous = watcher.withLock { current in
            defer { current = installed }
            return current
        }
        if let previous { await MainActor.run { previous.stop() } }
        let apps = await MainActor.run(body: AppInfo27.regularApps)
        let unobservable = await withTaskGroup(of: UnobservableApp?.self) { group in
            for app in apps { group.addTask { await observation.observe(app) } }
            var failed: [UnobservableApp] = []
            for await result in group { if let result { failed.append(result) } }
            return failed.sorted { $0.pid < $1.pid }
        }
        for app in unobservable {
            PlatformLog.windows.notice("Cannot observe \(app.bundleID ?? "an app", privacy: .public)")
        }
        return unobservable
    }

    func observeAgain(pids: Set<Int32>) async -> [UnobservableApp] {
        let observation = observation
        let apps = pids.compactMap(AppInfo27.running(pid:))
        return await withTaskGroup(of: UnobservableApp?.self) { group in
            for app in apps { group.addTask { await observation.observeAgain(app) } }
            var failed: [UnobservableApp] = []
            for await result in group { if let result { failed.append(result) } }
            return failed.sorted { $0.pid < $1.pid }
        }
    }

    func stopObserving() async {
        observation.end()
        let installed = watcher.withLock { $0.take() }
        if let installed { await MainActor.run { installed.stop() } }
    }
}
