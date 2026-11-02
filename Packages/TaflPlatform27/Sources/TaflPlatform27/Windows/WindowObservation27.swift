import AppKit
import ApplicationServices
import Synchronization
import TaflCore

/// The observers for every app: registers them, tells launches from quits, and hands their
/// notifications to the translator.
///
/// An app is registered once per observing run: at start, when it launches, or when a query first meets
/// it (an app can become a regular app after it launches). Each registration holds a claim on its pid.
/// A claim ends when the app quits or the run ends, and work still in flight under an ended claim does
/// nothing, even if the pid is claimed again by a new app.
final class WindowObservation27: Sendable {
    /// What the observation asks of the system, so a test can stand in for it.
    struct Environment: Sendable {
        /// Whether the process is still there. A pid that is not running is never registered or reported.
        var isRunning: @Sendable (Int32) -> Bool
        var isLaunching: @Sendable (Int32) -> Bool
        var untilFinishedLaunching: @Sendable (Int32) async -> Void
        var register: @Sendable (AXObserverHub, Int32, String?, @escaping AXObserverHub.Handler) -> [String: AXError]
        /// The app's windows that the registry did not have, as snapshots.
        var newWindows: @Sendable (AppInfo27) async -> [WindowSnapshot]

        static func live(catalog: WindowCatalog27) -> Environment {
            Environment(
                isRunning: { pid in
                    guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
                    return !app.isTerminated
                },
                isLaunching: { LaunchWait.isLaunching(pid: $0) },
                untilFinishedLaunching: { await LaunchWait.untilFinished(pid: $0) },
                register: { hub, pid, bundleID, handler in hub.observe(pid: pid, bundleID: bundleID, handler: handler) },
                newWindows: { app in await catalog.windows(of: app).filter(\.isNew).map(\.snapshot) })
        }
    }

    enum Outcome {
        case observed
        case unobservable(UnobservableApp)
        /// The first try timed out on an app still launching; the task tries again when it has finished.
        case retrying(Task<Void, Never>)
    }

    private struct State {
        var isActive = false
        var nextClaim = 0
        var claims: [Int32: Int] = [:]
    }

    private let hub = AXObserverHub()
    private let axQueue: AXQueue
    private let registry: WindowRegistry
    private let translator: WindowEventTranslator
    private let events: AsyncStream<PlatformEvent>.Continuation
    private let environment: Environment
    private let state = Mutex(State())

    init(
        axQueue: AXQueue, registry: WindowRegistry, catalog: WindowCatalog27,
        events: AsyncStream<PlatformEvent>.Continuation,
        environment: Environment? = nil
    ) {
        self.axQueue = axQueue
        self.registry = registry
        self.events = events
        self.environment = environment ?? .live(catalog: catalog)
        translator = WindowEventTranslator(registry: registry, reader: .live(axQueue: axQueue), events: events)
    }

    deinit {
        translator.closeAll()
    }

    func begin() {
        state.withLock { state in
            state.isActive = true
            state.claims = [:]
        }
    }

    func end() {
        state.withLock { state in
            state.isActive = false
            state.claims = [:]
        }
        hub.stopAll()
    }

    /// Registers an app that has not been registered in this run. The app is the result when its
    /// events cannot be observed. An app that was still launching gets one more try when it finishes,
    /// and the outcome of that arrives as an event.
    func observe(_ app: AppInfo27, announcingWindows: Bool = false) async -> UnobservableApp? {
        if case .unobservable(let unobservable) = await attempt(app, announcingWindows: announcingWindows) { return unobservable }
        return nil
    }

    func attempt(_ app: AppInfo27, announcingWindows: Bool = false) async -> Outcome {
        let pid = app.pid
        guard environment.isRunning(pid), let claim = claim(pid) else { return .observed }
        // The app may have quit between the check and the claim, after its quit was handled: the claim
        // would then never be released.
        guard environment.isRunning(pid) else {
            release(pid: pid, claim: claim)
            return .observed
        }
        guard let failures = await register(app, claim: claim) else { return .observed }
        if failures.isEmpty {
            if announcingWindows { await announceWindows(of: app) }
            return .observed
        }
        if Self.needsRetry(failures), environment.isLaunching(pid) {
            return .retrying(Task {
                await self.environment.untilFinishedLaunching(pid)
                guard let again = await self.register(app, claim: claim) else { return }
                if again.isEmpty {
                    await self.announceWindows(of: app)
                } else if self.isLive(pid: pid, claim: claim) {
                    self.yieldUnobservable(Self.unobservable(app, again))
                }
            })
        }
        guard isLive(pid: pid, claim: claim) else { return .observed }
        return .unobservable(Self.unobservable(app, failures))
    }

    /// Meets an app a query found: observes it if this run has not.
    func discover(_ app: AppInfo27) async {
        if let unobservable = await observe(app) { yieldUnobservable(unobservable) }
    }

    func appLaunched(_ app: AppInfo27) async {
        events.yield(.appLaunched(pid: app.pid, bundleID: app.bundleID))
        if let unobservable = await observe(app, announcingWindows: true) { yieldUnobservable(unobservable) }
    }

    /// Ends the app's claim, so nothing still in flight for it reports or registers, and frees what it held.
    func appQuit(pid: Int32) async {
        events.yield(.appQuit(pid: pid))
        let wasClaimed = state.withLock { $0.claims.removeValue(forKey: pid) != nil }
        if wasClaimed {
            let hub = hub
            await axQueue.run(pid: pid) { hub.stopObserving(pid: pid) }
        }
        translator.closeLane(pid: pid)
        await registry.removeApp(pid: pid)
        await axQueue.forget(pid: pid)
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

    /// A claim on the pid, or nil when observing is off, the app has one, or the app is Tafl itself.
    private func claim(_ pid: Int32) -> Int? {
        let claim = state.withLock { state -> Int? in
            guard state.isActive, pid != getpid(), state.claims[pid] == nil else { return nil }
            state.nextClaim += 1
            state.claims[pid] = state.nextClaim
            return state.nextClaim
        }
        if claim != nil { translator.reopen(pid: pid) }
        return claim
    }

    private func release(pid: Int32, claim: Int) {
        state.withLock { state in
            if state.claims[pid] == claim { state.claims[pid] = nil }
        }
    }

    private func isCurrent(pid: Int32, claim: Int) -> Bool {
        state.withLock { $0.isActive && $0.claims[pid] == claim }
    }

    /// The claim is still held and the process is still there.
    private func isLive(pid: Int32, claim: Int) -> Bool {
        isCurrent(pid: pid, claim: claim) && environment.isRunning(pid)
    }

    /// Runs on the app's `AXQueue`. Nil when the claim had ended or the process was gone, before the hop
    /// (so no queue is made for a dead pid) or while the call was in flight; in the second case the
    /// registration is taken back.
    private func register(_ app: AppInfo27, claim: Int) async -> [String: AXError]? {
        guard isLive(pid: app.pid, claim: claim) else { return nil }
        let hub = hub
        let translator = translator
        let register = environment.register
        let pid = app.pid
        let bundleID = app.bundleID
        return await axQueue.run(pid: pid) { () -> [String: AXError]? in
            guard self.isLive(pid: pid, claim: claim) else { return nil }
            let failures = register(hub, pid, bundleID) { event in translator.enqueue(event) }
            guard self.isCurrent(pid: pid, claim: claim) else {
                hub.stopObserving(pid: pid)
                return nil
            }
            return failures
        }
    }

    /// The windows the app already has when its events start: the ones no notification will announce.
    private func announceWindows(of app: AppInfo27) async {
        for snapshot in await environment.newWindows(app) {
            events.yield(.windowCreated(snapshot))
        }
    }

    private func yieldUnobservable(_ app: UnobservableApp) {
        PlatformLog.windows.notice("Cannot observe \(app.bundleID ?? "an app", privacy: .public)")
        events.yield(.unobservable(pid: app.pid, bundleID: app.bundleID, missing: app.missing))
    }
}
