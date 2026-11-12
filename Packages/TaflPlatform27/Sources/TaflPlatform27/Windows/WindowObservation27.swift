import AppKit
import ApplicationServices
import Synchronization
import TaflCore

/// The observers for every app: registers them, tells launches from quits, and hands their
/// notifications to the translator.
///
/// An app is registered once per observing run: at start, when it launches, or when a query first meets
/// it (an app can become a regular app after it launches). An app still launching when Tafl starts is
/// met as its launch. Each registration holds a claim on its pid.
/// A claim ends when the app quits, the run ends, or a registration asked for again replaces it, and work
/// still in flight under an ended claim does nothing, even if the pid is claimed again by a new app.
///
/// Every registration publishes its outcome, the events the app misses, as one event under its claim,
/// inside the registration's block on the app's queue: it comes before any window the registration
/// announces, and a window is announced only while the claim's latest registration observes placement.
/// A registration that fails while the app is still launching is made once more when it has finished.
/// A launch's or a query's first meeting that still fails is made again at each of the retry delays
/// after that failure, under the same claim, until one succeeds; the claim's end ends those tries.
final class WindowObservation27: Sendable {
    /// What the observation asks of the system, so a test can stand in for it.
    struct Environment: Sendable {
        /// Whether the process is still there. A pid that is not running is never registered or reported.
        var isRunning: @Sendable (Int32) -> Bool
        var isLaunching: @Sendable (Int32) -> Bool
        var untilFinishedLaunching: @Sendable (Int32) async -> Void
        var register: @Sendable (AXObserverHub, Int32, String?, @escaping AXObserverHub.Handler) -> [String: AXError]
        /// Takes back whatever `register` left registered for the pid.
        var stop: @Sendable (AXObserverHub, Int32) -> Void = { hub, pid in hub.stopObserving(pid: pid) }
        /// The app's windows, registered, each handed to `announce` inside the read that found it.
        var windows: @Sendable (
            AppInfo27,
            _ announce: @escaping @Sendable (WindowCatalog27.Entry) -> WindowRegistry.Announcement
        ) async -> [Found]
        /// The reads the translator makes for the windows the app's notifications name.
        var reader: WindowReader27
        /// Waits before a try. It throws when the try's claim has ended, which cancels its task.
        var sleep: @Sendable (Duration) async throws -> Void

        static func live(catalog: WindowCatalog27, axQueue: AXQueue, clock: any TaflClock) -> Environment {
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
                },
                reader: .live(axQueue: axQueue),
                sleep: { try await clock.sleep(for: $0) })
        }
    }

    /// A window a catch-up found, and what announcing it came to.
    struct Found: Sendable {
        var entry: WindowCatalog27.Entry
        var announcement: WindowRegistry.Announcement
    }

    private struct Claim {
        var id: Int
        /// Whether the claim's latest registration observes what placement needs; nil until one has.
        var observesPlacement: Bool?
        /// The tries that follow a failed registration under the claim: the claim's end cancels them.
        var tries: Task<Void, Never>?
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

    /// What a registration came to, once its outcome was published.
    private struct Registered {
        var failures: [String: AXError]
        /// It failed while the app was still launching: it is made once more when the app has finished.
        var awaitsLaunch: Bool
    }

    private let hub = AXObserverHub()
    private let axQueue: AXQueue
    private let registry: WindowRegistry
    private let translator: WindowEventTranslator
    private let events: AsyncStream<PlatformEvent>.Continuation
    private let notices: any WindowNotices
    private let environment: Environment
    /// When, measured from a failure that ends a launch's or a query's first registration, the app is
    /// registered again.
    private let retryDelays: [Duration]
    private let state = Mutex(State())

    init(
        axQueue: AXQueue, registry: WindowRegistry,
        events: AsyncStream<PlatformEvent>.Continuation,
        notices: any WindowNotices,
        retryDelays: [Duration],
        environment: Environment
    ) {
        self.axQueue = axQueue
        self.registry = registry
        self.events = events
        self.notices = notices
        self.retryDelays = retryDelays
        self.environment = environment
        translator = WindowEventTranslator(registry: registry, reader: environment.reader, events: events, notices: notices)
    }

    deinit {
        translator.closeAll()
    }

    func begin() {
        endClaims(active: true)
    }

    func end() {
        endClaims(active: false)
        hub.stopAll()
    }

    /// Registers an app this run has not registered, as a start of observing does. The app is the
    /// result when that registration finds it unobservable. One still launching is registered once more
    /// when it has finished, and that outcome arrives only as an event. At Tafl's start an app still
    /// launching is met as its launch: its windows are owed, and a failure is tried as a launch's is. A
    /// restart leaves a failure to its own tries.
    func observe(_ app: AppInfo27, as run: ObservingRun) async -> UnobservableApp? {
        if run == .start, environment.isLaunching(app.pid) { return await meetLaunch(app) }
        guard let claim = claimIfRunning(app.pid) else { return nil }
        return await attempt(app, under: claim, delays: [], isRetry: false)
    }

    /// Registers an app this run already claimed once more, after a registration that failed (for
    /// about 2 s around a wake, Accessibility calls on live apps fail). A new claim replaces the old one
    /// in one step, so nothing still in flight under the old one does anything, its tries end, and the
    /// app is never without a claim. The app is the result when this registration still finds it
    /// unobservable; nil when it observes, or when the app is gone or was never claimed. An app still
    /// launching is not waited for: its registration once it has finished publishes its own outcome.
    func observeAgain(_ app: AppInfo27) async -> UnobservableApp? {
        guard let claim = replaceClaim(pid: app.pid) else { return nil }
        return await attempt(app, under: claim, delays: [], isRetry: true)
    }

    /// Meets an app a query found: observes it if this run has not, and tries again as a launch does
    /// when that fails. A query never announces windows.
    func discover(_ app: AppInfo27) async {
        guard let claim = claimIfRunning(app.pid) else { return }
        _ = await attempt(app, under: claim, delays: retryDelays, isRetry: false)
    }

    func appLaunched(_ app: AppInfo27) async {
        events.yield(.appLaunched(pid: app.pid, bundleID: app.bundleID))
        _ = await meetLaunch(app)
    }

    /// A launch owes the app's windows their announcement, whoever claims the app: when a query
    /// claimed it first, its registration pays the debt, or the launch does once it has. A failed
    /// registration is tried again at the retry delays. The app is the result when the launch's own
    /// registration finds it unobservable.
    private func meetLaunch(_ app: AppInfo27) async -> UnobservableApp? {
        let held = owe(app.pid)
        var unobservable: UnobservableApp?
        if let claim = claimIfRunning(app.pid) {
            unobservable = await attempt(app, under: claim, delays: retryDelays, isRetry: false)
        }
        if let held, held.observesPlacement == true { await catchUp(app, claim: held.id) }
        return unobservable
    }

    /// Ends the app's claim and its tries, so nothing still in flight for it reports or registers, and
    /// frees what it held. The notices hear of the quit on the app's queue, after the reads already there.
    func appQuit(pid: Int32) async {
        // Under the lock every outcome and announcement take: nothing found under the claim arrives after
        // the quit.
        let ended = state.withLock { state -> Claim? in
            events.yield(.appQuit(pid: pid))
            state.owed.remove(pid)
            return state.claims.removeValue(forKey: pid)
        }
        ended?.tries?.cancel()
        let wasClaimed = ended != nil
        let hub = hub
        let notices = notices
        let stop = environment.stop
        await axQueue.run(pid: pid) {
            if wasClaimed { stop(hub, pid) }
            notices.quit(pid: pid)
        }
        translator.closeLane(pid: pid)
        registry.removeApp(pid: pid)
        await axQueue.forget(pid: pid)
    }

    /// The tries under the app's current claim, for a test to wait on.
    func tries(of pid: Int32) -> Task<Void, Never>? {
        state.withLock { $0.claims[pid]?.tries }
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

    // MARK: Registering

    /// The first registration under a claim, and the tries that follow it when it fails: once the app
    /// has finished launching, if it was still launching, then after each of `delays`. The app is the
    /// result when the first registration published it unobservable.
    private func attempt(
        _ app: AppInfo27, under claim: Int, delays: [Duration], isRetry: Bool
    ) async -> UnobservableApp? {
        // The app may have quit between the check and the claim, after its quit was handled: the claim
        // would then never be released.
        guard environment.isRunning(app.pid) else {
            abandon(pid: app.pid, claim: claim)
            return nil
        }
        guard let first = await register(app, claim: claim, awaitingLaunch: true, delays: delays, isRetry: isRetry),
              !first.failures.isEmpty
        else { return nil }
        if first.awaitsLaunch || !delays.isEmpty {
            startTries(app, claim: claim, awaitingLaunch: first.awaitsLaunch, delays: delays)
        }
        return UnobservableApp(pid: app.pid, bundleID: app.bundleID, missing: Self.observedEvents(for: Set(first.failures.keys)))
    }

    /// The tries after a failed registration, in a task the claim holds, so the claim's end cancels them
    /// and they hold up no other app. The delays count from the failure that ends the launch wait.
    private func startTries(_ app: AppInfo27, claim: Int, awaitingLaunch: Bool, delays: [Duration]) {
        let pid = app.pid
        let tries = Task {
            if awaitingLaunch {
                await self.environment.untilFinishedLaunching(pid)
                guard !Task.isCancelled else { return }
                // The app was still launching: its windows are new, and the next registration owes them
                // their announcement.
                _ = self.owe(pid)
                guard let registered = await self.register(app, claim: claim, awaitingLaunch: false, delays: delays, isRetry: true),
                      !registered.failures.isEmpty
                else { return }
            }
            var waited = Duration.zero
            for (index, delay) in delays.enumerated() {
                do { try await self.environment.sleep(delay - waited) } catch { return }
                waited = delay
                let left = Array(delays.dropFirst(index + 1))
                guard let registered = await self.register(app, claim: claim, awaitingLaunch: false, delays: left, isRetry: true),
                      !registered.failures.isEmpty
                else { return }
            }
        }
        let held = state.withLock { state -> Bool in
            guard state.isActive, state.claims[pid]?.id == claim else { return false }
            state.claims[pid]?.tries = tries
            return true
        }
        if !held { tries.cancel() }
    }

    /// One registration under the claim, on the app's `AXQueue`: it registers, records what the
    /// registration observes and publishes its outcome in one block, before anything the registration
    /// announces, then pays the app's launch debt when it can. Nil, with nothing published, when the
    /// claim had ended or the process was gone, before the hop (so no queue is made for a dead pid) or
    /// while the call was in flight; in the second case the registration is taken back. A failure counts
    /// as retrying when a try follows it: once the app has finished launching, or after `delays`.
    private func register(
        _ app: AppInfo27, claim: Int, awaitingLaunch: Bool, delays: [Duration], isRetry: Bool
    ) async -> Registered? {
        guard isLive(pid: app.pid, claim: claim) else {
            abandon(pid: app.pid, claim: claim)
            return nil
        }
        let hub = hub
        let translator = translator
        let environment = environment
        let pid = app.pid
        // The window a creation names is announced only under this claim, as a catch-up's is.
        let announce: @Sendable (PlatformEvent) -> Bool = { [weak self] event in
            self?.announce(event, pid: pid, claim: claim) ?? false
        }
        let registered = await axQueue.run(pid: pid) { () -> (Registered, owes: Bool)? in
            guard self.isLive(pid: pid, claim: claim) else {
                self.abandon(pid: pid, claim: claim)
                return nil
            }
            let failures = environment.register(hub, pid, app.bundleID) { event in translator.enqueue(event, announce: announce) }
            guard environment.isRunning(pid) else {
                // Gone while the call was in flight: nothing is reported, and its quit takes the
                // registration back, or this does when the claim has ended already.
                if !self.isCurrent(pid: pid, claim: claim) { environment.stop(hub, pid) }
                return nil
            }
            let awaitsLaunch = awaitingLaunch && Self.needsRetry(failures) && environment.isLaunching(pid)
            let retrying = !failures.isEmpty && (awaitsLaunch || !delays.isEmpty)
            guard let owes = self.publishOutcome(app, claim: claim, failures: failures, retrying: retrying, isRetry: isRetry) else {
                environment.stop(hub, pid)
                return nil
            }
            return (Registered(failures: failures, awaitsLaunch: awaitsLaunch), owes)
        }
        if registered?.owes == true { await catchUp(app, claim: claim) }
        return registered?.0
    }

    /// Records what the registration under the claim observes and publishes its outcome, under the
    /// lock `appQuit`, `end` and every announcement take. Nil when the claim has ended, so nothing it
    /// found is published; otherwise whether the registration can pay the app's launch debt. A published
    /// outcome is logged.
    private func publishOutcome(
        _ app: AppInfo27, claim: Int, failures: [String: AXError], retrying: Bool, isRetry: Bool
    ) -> Bool? {
        let missing = Self.observedEvents(for: Set(failures.keys))
        let observesPlacement = Self.observesPlacement(failures)
        let owes = state.withLock { state -> Bool? in
            guard state.isActive, state.claims[app.pid]?.id == claim else { return nil }
            state.claims[app.pid]?.observesPlacement = observesPlacement
            events.yield(.observability(pid: app.pid, bundleID: app.bundleID, missing: missing, retrying: retrying))
            return observesPlacement && state.owed.contains(app.pid)
        }
        guard let owes else { return nil }
        let name = app.bundleID ?? "an app"
        if !failures.isEmpty {
            PlatformLog.windows.notice("Cannot observe \(name, privacy: .public)")
        } else if isRetry {
            PlatformLog.windows.notice("Observing \(name, privacy: .public) again")
        }
        return owes
    }

    // MARK: Claims

    /// A claim on the pid of a running app, or nil when observing is off, the app has one, or the app
    /// is Tafl itself.
    private func claimIfRunning(_ pid: Int32) -> Int? {
        guard environment.isRunning(pid) else { return nil }
        let claim = state.withLock { state -> Int? in
            guard state.isActive, pid != getpid(), state.claims[pid] == nil else { return nil }
            state.nextClaim += 1
            state.claims[pid] = Claim(id: state.nextClaim)
            return state.nextClaim
        }
        if claim != nil { translator.reopen(pid: pid) }
        return claim
    }

    /// Puts a new claim in place of the one the app holds, and ends the old one's tries; nil when it
    /// holds none or observing is off.
    private func replaceClaim(pid: Int32) -> Int? {
        let (claim, ended) = state.withLock { state -> (Int?, Claim?) in
            guard state.isActive, let old = state.claims[pid] else { return (nil, nil) }
            state.nextClaim += 1
            state.claims[pid] = Claim(id: state.nextClaim)
            return (state.nextClaim, old)
        }
        ended?.tries?.cancel()
        return claim
    }

    /// An attempt under the claim gives up: the claim is released, if it is still the app's, and so is
    /// whatever registration the app has. Under the lock, so a claim taken afterwards registers fresh.
    private func abandon(pid: Int32, claim: Int) {
        let ended = state.withLock { state -> Claim? in
            guard let held = state.claims[pid], held.id == claim else { return nil }
            state.claims[pid] = nil
            environment.stop(hub, pid)
            return held
        }
        ended?.tries?.cancel()
    }

    /// Ends every claim and its tries, with observing on or off afterwards.
    private func endClaims(active: Bool) {
        let ended = state.withLock { state -> [Claim] in
            state.isActive = active
            defer { state.claims = [:] }
            return Array(state.claims.values)
        }
        for claim in ended { claim.tries?.cancel() }
    }

    private func isCurrent(pid: Int32, claim: Int) -> Bool {
        state.withLock { $0.isActive && $0.claims[pid]?.id == claim }
    }

    /// The claim is still held and the process is still there.
    private func isLive(pid: Int32, claim: Int) -> Bool {
        isCurrent(pid: pid, claim: claim) && environment.isRunning(pid)
    }

    // MARK: Announcing

    /// Owes the app's windows their announcement. The current claim on the app, if any, and what
    /// its registration observes, taken under the same lock `publishOutcome` records it under: one of
    /// the two sees the other, so the debt is paid.
    private func owe(_ pid: Int32) -> Claim? {
        state.withLock { state in
            state.owed.insert(pid)
            return state.isActive ? state.claims[pid] : nil
        }
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
            registry.announce(entry.snapshot) { event in self.announce(event, pid: app.pid, claim: claim) }
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

    /// Publishes a window's announcement found under the claim, only while the claim holds and its
    /// latest registration observes placement. It takes the lock `appQuit`, `end` and every outcome
    /// take, so no window is announced under an ended claim, nor ahead of the outcome that lets it be.
    /// The notices hear of it before its event.
    private func announce(_ event: PlatformEvent, pid: Int32, claim: Int) -> Bool {
        state.withLock { state in
            guard state.isActive, let held = state.claims[pid], held.id == claim, held.observesPlacement == true
            else { return false }
            if case .windowCreated(let snapshot) = event { notices.announced(snapshot) }
            events.yield(event)
            return true
        }
    }
}
