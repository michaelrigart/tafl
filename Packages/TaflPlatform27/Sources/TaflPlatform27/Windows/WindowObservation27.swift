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
        /// The app's windows, registered, each handed to `announce` inside the read that found it.
        var windows: @Sendable (
            AppInfo27,
            _ announce: @escaping @Sendable (WindowCatalog27.Entry) -> WindowRegistry.Announcement
        ) async -> [Found]

        static func live(catalog: WindowCatalog27) -> Environment {
            Environment(
                isRunning: { pid in
                    guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
                    return !app.isTerminated
                },
                isLaunching: { LaunchWait.isLaunching(pid: $0) },
                untilFinishedLaunching: { await LaunchWait.untilFinished(pid: $0) },
                register: { hub, pid, bundleID, handler in hub.observe(pid: pid, bundleID: bundleID, handler: handler) },
                windows: { app, announce in
                    await catalog.windows(of: app) { Found(entry: $0, announcement: announce($0)) }
                })
        }
    }

    /// A window a catch-up found, and what announcing it came to.
    struct Found: Sendable {
        var entry: WindowCatalog27.Entry
        var announcement: WindowRegistry.Announcement
    }

    enum Outcome {
        case observed
        case unobservable(UnobservableApp)
        /// The first try timed out on an app still launching; the task tries again when it has finished.
        case retrying(Task<Void, Never>)
    }

    private struct Claim {
        var id: Int
        /// Whether the registration under the claim observes what placement needs; nil while it runs.
        var observesPlacement: Bool?
    }

    private struct State {
        var isActive = false
        var nextClaim = 0
        var claims: [Int32: Claim] = [:]
        /// Apps whose launch still owes their windows an announcement. A debt outlives a restart of
        /// observing: whichever registration of the app comes next pays it. It goes when paid, or
        /// when the app quits.
        var owed: Set<Int32> = []
    }

    private let hub = AXObserverHub()
    private let axQueue: AXQueue
    private let registry: WindowRegistry
    private let translator: WindowEventTranslator
    private let events: AsyncStream<PlatformEvent>.Continuation
    private let notices: any WindowNotices
    private let environment: Environment
    private let state = Mutex(State())

    init(
        axQueue: AXQueue, registry: WindowRegistry, catalog: WindowCatalog27,
        events: AsyncStream<PlatformEvent>.Continuation,
        notices: any WindowNotices,
        environment: Environment? = nil
    ) {
        self.axQueue = axQueue
        self.registry = registry
        self.events = events
        self.notices = notices
        self.environment = environment ?? .live(catalog: catalog)
        translator = WindowEventTranslator(
            registry: registry, reader: .live(axQueue: axQueue), events: events, notices: notices
        )
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
    func observe(_ app: AppInfo27) async -> UnobservableApp? {
        if case .unobservable(let unobservable) = await attempt(app) { return unobservable }
        return nil
    }

    func attempt(_ app: AppInfo27) async -> Outcome {
        await claimedAttempt(app).outcome
    }

    /// The outcome, and the claim it was reached under when there is one.
    private func claimedAttempt(_ app: AppInfo27) async -> (outcome: Outcome, claim: Int?) {
        let pid = app.pid
        guard environment.isRunning(pid), let claim = claim(pid) else { return (.observed, nil) }
        // The app may have quit between the check and the claim, after its quit was handled: the claim
        // would then never be released.
        guard environment.isRunning(pid) else {
            release(pid: pid, claim: claim)
            return (.observed, nil)
        }
        guard let failures = await register(app, claim: claim) else { return (.observed, nil) }
        if Self.needsRetry(failures), environment.isLaunching(pid) {
            return (.retrying(Task {
                await self.environment.untilFinishedLaunching(pid)
                // The app was still launching: its windows are new, and the retry owes them their announcement.
                _ = self.owe(pid)
                guard let again = await self.register(app, claim: claim) else { return }
                await self.registered(app, claim: claim, failures: again)
                if !again.isEmpty, self.environment.isRunning(pid) {
                    self.publishUnobservable(Self.unobservable(app, again), claim: claim)
                }
            }), claim)
        }
        await registered(app, claim: claim, failures: failures)
        guard !failures.isEmpty, isLive(pid: pid, claim: claim) else { return (.observed, claim) }
        return (.unobservable(Self.unobservable(app, failures)), claim)
    }

    /// Registers an app this run already claimed once more, after a registration that failed (for
    /// about 2 s around a wake, Accessibility calls on live apps fail). The old claim ends, so
    /// nothing still in flight under it does anything. The app is the result when its events still
    /// cannot be observed; nil when they can, or when the app is gone or was never claimed. Each
    /// outcome is logged.
    func observeAgain(_ app: AppInfo27) async -> UnobservableApp? {
        let wasClaimed = state.withLock { state in
            state.isActive && state.claims.removeValue(forKey: app.pid) != nil
        }
        guard wasClaimed else { return nil }
        let attempt = await claimedAttempt(app)
        guard attempt.claim != nil else { return nil }
        switch attempt.outcome {
        case .unobservable(let unobservable):
            PlatformLog.windows.notice("Cannot observe \(app.bundleID ?? "an app", privacy: .public)")
            return unobservable
        case .observed:
            PlatformLog.windows.notice("Observing \(app.bundleID ?? "an app", privacy: .public) again after wake")
            return nil
        case .retrying:
            // Still launching: the retry's outcome arrives as an event.
            return nil
        }
    }

    /// Meets an app a query found: observes it if this run has not. A query never announces windows.
    func discover(_ app: AppInfo27) async {
        await observeReporting(app)
    }

    /// A launch owes the app's windows their announcement, whoever claims the app: when a query
    /// claimed it first, its registration pays the debt, or the launch does once it has.
    func appLaunched(_ app: AppInfo27) async {
        events.yield(.appLaunched(pid: app.pid, bundleID: app.bundleID))
        let held = owe(app.pid)
        await observeReporting(app)
        if let held, held.observesPlacement == true { await catchUp(app, claim: held.id) }
    }

    /// Observes the app and publishes, under its claim, that it cannot be observed when so.
    private func observeReporting(_ app: AppInfo27) async {
        let attempt = await claimedAttempt(app)
        if case .unobservable(let unobservable) = attempt.outcome, let claim = attempt.claim {
            publishUnobservable(unobservable, claim: claim)
        }
    }

    /// Ends the app's claim, so nothing still in flight for it reports or registers, and frees what it
    /// held. The notices hear of the quit on the app's queue, after the reads already there.
    func appQuit(pid: Int32) async {
        // Under the lock `publish` takes: nothing found under the claim arrives after the quit.
        let wasClaimed = state.withLock { state in
            events.yield(.appQuit(pid: pid))
            state.owed.remove(pid)
            return state.claims.removeValue(forKey: pid) != nil
        }
        let hub = hub
        let notices = notices
        await axQueue.run(pid: pid) {
            if wasClaimed { hub.stopObserving(pid: pid) }
            notices.quit(pid: pid)
        }
        translator.closeLane(pid: pid)
        registry.removeApp(pid: pid)
        await axQueue.forget(pid: pid)
    }

    static func needsRetry(_ failures: [String: AXError]) -> Bool {
        failures.values.contains(.cannotComplete)
    }

    /// Whether what placement needs is observed (creations, moves, resizes, destructions): a missing
    /// title-change observation costs only the first-title check.
    static func observesPlacement(_ failures: [String: AXError]) -> Bool {
        observedEvents(for: Set(failures.keys)).isSubset(of: [.titleChanged])
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
            state.claims[pid] = Claim(id: state.nextClaim)
            return state.nextClaim
        }
        if claim != nil { translator.reopen(pid: pid) }
        return claim
    }

    private func release(pid: Int32, claim: Int) {
        state.withLock { state in
            if state.claims[pid]?.id == claim { state.claims[pid] = nil }
        }
    }

    private func isCurrent(pid: Int32, claim: Int) -> Bool {
        state.withLock { $0.isActive && $0.claims[pid]?.id == claim }
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

    /// Owes the app's windows their announcement. The current claim on the app, if any, and what
    /// its registration observes, taken under the same lock `registered` records it under: one of
    /// the two sees the other, so the debt is paid.
    private func owe(_ pid: Int32) -> Claim? {
        state.withLock { state in
            state.owed.insert(pid)
            return state.isActive ? state.claims[pid] : nil
        }
    }

    /// Records what the registration under the claim observes, and pays the app's debt when it can.
    private func registered(_ app: AppInfo27, claim: Int, failures: [String: AXError]) async {
        let observesPlacement = Self.observesPlacement(failures)
        let owes = state.withLock { state -> Bool in
            guard state.isActive, state.claims[app.pid]?.id == claim else { return false }
            state.claims[app.pid]?.observesPlacement = observesPlacement
            return observesPlacement && state.owed.contains(app.pid)
        }
        if owes { await catchUp(app, claim: claim) }
    }

    /// Announces the windows the app has, which no notification will: each one not yet announced,
    /// whoever registered it, in the registry's one announcing step under this claim, inside the read
    /// that found it. Only a catch-up whose every step ran under its current claim pays the launch's
    /// debt. A step under an ended claim (the app quit, or observing restarted) announces nothing and
    /// marks nothing. The catch-up's registrations stay while the app runs, for whoever adopts them;
    /// when its claim has ended and the app is no longer running, it withdraws those it made itself.
    private func catchUp(_ app: AppInfo27, claim: Int) async {
        let registry = registry
        let found = await environment.windows(app) { entry in
            registry.announce(entry.snapshot) { event in self.publish([event], pid: app.pid, claim: claim) }
        }
        if !found.contains(where: { $0.announcement == .refused }) { payDebt(of: app.pid, claim: claim) }
        if !isCurrent(pid: app.pid, claim: claim), !environment.isRunning(app.pid) {
            // Its claim ended and the app has exited. The withdraw delivers no end: the app's quit event,
            // delivered or still to come, makes the core forget every window the app had.
            _ = registry.withdraw(found.map(\.entry).filter(\.isNew).map { ($0.snapshot.handle, $0.element) })
        }
    }

    /// Clears the launch's debt, only while the claim the catch-up ran under is current.
    private func payDebt(of pid: Int32, claim: Int) {
        state.withLock { state in
            if state.isActive, state.claims[pid]?.id == claim { state.owed.remove(pid) }
        }
    }

    private func publishUnobservable(_ app: UnobservableApp, claim: Int) {
        let event = PlatformEvent.unobservable(pid: app.pid, bundleID: app.bundleID, missing: app.missing)
        guard publish([event], pid: app.pid, claim: claim) else { return }
        PlatformLog.windows.notice("Cannot observe \(app.bundleID ?? "an app", privacy: .public)")
    }

    /// Publishes what was found under a claim, only while the claim holds. It takes the lock `appQuit`
    /// and `end` take, so nothing an ended claim found arrives after the app's quit or a restart. An
    /// announcement reaches the notices before its event.
    private func publish(_ found: [PlatformEvent], pid: Int32, claim: Int) -> Bool {
        state.withLock { state in
            guard state.isActive, state.claims[pid]?.id == claim else { return false }
            for event in found {
                if case .windowCreated(let snapshot) = event { notices.announced(snapshot) }
                events.yield(event)
            }
            return true
        }
    }
}
