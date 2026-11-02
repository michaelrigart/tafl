import ApplicationServices
import Synchronization
import TaflCore

/// The observers for every app: registers them, tells launches from quits, and hands their
/// notifications to the translator.
///
/// An app is registered once per observing run: at start, when it launches, or when a query first meets
/// it (an app can become a regular app after it launches). A run ends at `end()`; work still in flight
/// from the earlier run does nothing.
final class WindowObservation27: Sendable {
    private struct State {
        var generation = 0
        var isActive = false
        var pids = Set<Int32>()
    }

    private let hub = AXObserverHub()
    private let axQueue: AXQueue
    private let registry: WindowRegistry
    private let catalog: WindowCatalog27
    private let translator: WindowEventTranslator
    private let events: AsyncStream<PlatformEvent>.Continuation
    private let state = Mutex(State())

    init(axQueue: AXQueue, registry: WindowRegistry, catalog: WindowCatalog27, events: AsyncStream<PlatformEvent>.Continuation) {
        self.axQueue = axQueue
        self.registry = registry
        self.catalog = catalog
        self.events = events
        translator = WindowEventTranslator(registry: registry, reader: .live(axQueue: axQueue), events: events)
    }

    deinit {
        translator.closeAll()
    }

    func begin() {
        state.withLock { state in
            state.generation += 1
            state.isActive = true
            state.pids = []
        }
    }

    func end() {
        state.withLock { state in
            state.generation += 1
            state.isActive = false
            state.pids = []
        }
        hub.stopAll()
    }

    /// Registers an app that has not been registered in this run. The app is the result when its
    /// events cannot be observed. An app that was still launching gets one more try when it finishes,
    /// and the outcome of that arrives as an event.
    func observe(_ app: AppInfo27, announcingWindows: Bool = false) async -> UnobservableApp? {
        guard let generation = claim(app.pid) else { return nil }
        let failures = await register(app, generation: generation)
        if failures.isEmpty {
            if announcingWindows { await announceWindows(of: app) }
            return nil
        }
        if Self.needsRetry(failures), LaunchWait.isLaunching(pid: app.pid) {
            Task {
                await LaunchWait.untilFinished(pid: app.pid)
                guard self.isCurrent(generation) else { return }
                let again = await self.register(app, generation: generation)
                if again.isEmpty {
                    await self.announceWindows(of: app)
                } else {
                    self.yieldUnobservable(Self.unobservable(app, again))
                }
            }
            return nil
        }
        return Self.unobservable(app, failures)
    }

    /// Meets an app a query found: observes it if this run has not.
    func discover(_ app: AppInfo27) async {
        if let unobservable = await observe(app) { yieldUnobservable(unobservable) }
    }

    func appLaunched(_ app: AppInfo27) async {
        events.yield(.appLaunched(pid: app.pid, bundleID: app.bundleID))
        if let unobservable = await observe(app, announcingWindows: true) { yieldUnobservable(unobservable) }
    }

    func appQuit(pid: Int32) async {
        events.yield(.appQuit(pid: pid))
        state.withLock { _ = $0.pids.remove(pid) }
        let hub = hub
        await axQueue.run(pid: pid) { hub.stopObserving(pid: pid) }
        translator.closeLane(pid: pid)
        await registry.removeApp(pid: pid)
    }

    static func needsRetry(_ failures: [String: AXError]) -> Bool {
        failures.values.contains(.cannotComplete)
    }

    static func observedEvents(for notifications: Set<String>) -> Set<ObservedEvent> {
        Set(notifications.compactMap { name in
            switch name {
            case kAXWindowCreatedNotification: .created
            case kAXWindowMovedNotification: .moved
            case kAXWindowResizedNotification: .resized
            case kAXTitleChangedNotification: .titleChanged
            case kAXUIElementDestroyedNotification: .destroyed
            default: nil
            }
        })
    }

    private static func unobservable(_ app: AppInfo27, _ failures: [String: AXError]) -> UnobservableApp {
        UnobservableApp(pid: app.pid, bundleID: app.bundleID, missing: observedEvents(for: Set(failures.keys)))
    }

    /// The generation this registration belongs to, or nil when observing is off or the app is registered.
    private func claim(_ pid: Int32) -> Int? {
        state.withLock { state in
            guard state.isActive, state.pids.insert(pid).inserted else { return nil }
            return state.generation
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        state.withLock { $0.isActive && $0.generation == generation }
    }

    /// Runs on the app's `AXQueue`. A run that ends while the call is in flight takes its registration back.
    private func register(_ app: AppInfo27, generation: Int) async -> [String: AXError] {
        let hub = hub
        let translator = translator
        let pid = app.pid
        let bundleID = app.bundleID
        return await axQueue.run(pid: pid) {
            guard self.isCurrent(generation) else { return [:] }
            let failures = hub.observe(pid: pid, bundleID: bundleID) { event in translator.enqueue(event) }
            if !self.isCurrent(generation) { hub.stopObserving(pid: pid) }
            return failures
        }
    }

    /// The windows the app already has when its events start: the ones no notification will announce.
    private func announceWindows(of app: AppInfo27) async {
        for entry in await catalog.windows(of: app) where entry.isNew {
            events.yield(.windowCreated(entry.snapshot))
        }
    }

    private func yieldUnobservable(_ app: UnobservableApp) {
        PlatformLog.windows.notice("Cannot observe \(app.bundleID ?? "an app", privacy: .public)")
        events.yield(.unobservable(pid: app.pid, bundleID: app.bundleID, missing: app.missing))
    }
}
