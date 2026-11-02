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
    private let observation: WindowObservation27
    private let watcher = Mutex<WorkspaceWatcher27?>(nil)

    init() {
        let (stream, continuation) = AsyncStream<PlatformEvent>.makeStream(bufferingPolicy: .unbounded)
        events = stream
        eventContinuation = continuation
        observation = WindowObservation27(axQueue: axQueue, registry: registry, events: continuation)
    }

    // MARK: Displays, settings, permission

    func displays() async -> [Display] {
        await Displays27.current(axQueue: axQueue)
    }

    func pointerDisplay() async -> DisplayIdentity? {
        Pointer27.display(in: await displays())
    }

    func tilingSettings() async -> TilingSettings {
        Tiling27().read()
    }

    func isAccessibilityGranted() async -> Bool {
        AXIsProcessTrusted()
    }

    func appName(pid: Int32) async -> String? {
        NSRunningApplication(processIdentifier: pid)?.localizedName
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

    func focusedWindow() async -> Result<WindowSnapshot, PlatformFailure> {
        guard let app = await MainActor.run(body: AppInfo27.frontmost) else { return .failure(.noWindow) }
        let pid = app.pid
        let read = await axQueue.run(pid: pid) { () -> Result<ElementRead, AXFailure>? in
            guard let element = AXWindowAccess.focusedWindow(of: pid) else { return nil }
            return Windows27.read(element, pid: pid, resolveID: true)
        }
        guard let read else { return .failure(.noWindow) }
        switch read {
        case .failure(let failure):
            return .failure(Windows27.failure(for: failure.code))
        case .success(let window):
            guard let snapshot = await register(window, app: app) else { return .failure(.noWindow) }
            return .success(snapshot)
        }
    }

    func visibleWindows() async -> [WindowSnapshot] {
        let apps = await MainActor.run(body: AppInfo27.regularApps)
        return await withTaskGroup(of: (Int, [WindowSnapshot]).self) { group in
            for (index, app) in apps.enumerated() {
                group.addTask { (index, await self.windows(of: app)) }
            }
            var parts: [(Int, [WindowSnapshot])] = []
            for await part in group { parts.append(part) }
            return parts.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
    }

    func snapshot(of handle: WindowHandle) async -> Result<WindowSnapshot, PlatformFailure> {
        guard let element = await registry.element(for: handle), let app = AppInfo27.running(pid: handle.pid) else {
            return .failure(.noWindow)
        }
        let pid = handle.pid
        switch await axQueue.run(pid: pid, { Windows27.read(element.element, pid: pid, resolveID: false) }) {
        case .failure(let failure):
            if failure.code == .invalidUIElement { await registry.remove(handle) }
            return .failure(Windows27.failure(for: failure.code))
        case .success(let window):
            guard let snapshot = Windows27.snapshot(handle: handle, app: app, attributes: window.attributes) else {
                return .failure(.noWindow)
            }
            return .success(snapshot)
        }
    }

    func beginWriting(_ handle: WindowHandle) async -> Result<any WriteSession, PlatformFailure> {
        guard let element = await registry.element(for: handle), let app = AppInfo27.running(pid: handle.pid) else {
            return .failure(.noWindow)
        }
        let assistiveTechnologyOn = await MainActor.run {
            NSWorkspace.shared.isVoiceOverEnabled || NSWorkspace.shared.isSwitchControlEnabled
        }
        let session = await WriteSession27.begin(
            element: element, app: app, assistiveTechnologyOn: assistiveTechnologyOn, axQueue: axQueue, leases: leases)
        return .success(session)
    }

    private func windows(of app: AppInfo27) async -> [WindowSnapshot] {
        let pid = app.pid
        let reads = await axQueue.run(pid: pid) {
            AXWindowAccess.windows(of: pid).compactMap { element -> ElementRead? in
                guard case .success(let window) = Windows27.read(element, pid: pid, resolveID: true) else { return nil }
                return window
            }
        }
        var snapshots: [WindowSnapshot] = []
        for window in reads {
            if let snapshot = await register(window, app: app) { snapshots.append(snapshot) }
        }
        return snapshots
    }

    private func register(_ window: ElementRead, app: AppInfo27) async -> WindowSnapshot? {
        guard Windows27.isTracked(window.attributes) else { return nil }
        let handle = await registry.handle(for: window.element, pid: app.pid, windowID: window.windowID)
        return Windows27.snapshot(handle: handle, app: app, attributes: window.attributes)
    }

    // MARK: Observing

    func startObserving() async -> [UnobservableApp] {
        await stopObserving()
        let events = eventContinuation
        let observation = observation
        let installed = await MainActor.run {
            let created = WorkspaceWatcher27()
            created.start(observation: observation, events: events)
            return created
        }
        watcher.withLock { $0 = installed }
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

    func stopObserving() async {
        let installed = watcher.withLock { $0.take() }
        if let installed { await MainActor.run { installed.stop() } }
        observation.stopAll()
    }
}
