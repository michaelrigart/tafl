import ApplicationServices
import Synchronization
import Testing
import TaflCore
import TaflTestSupport
@testable import TaflPlatform27

@Test func registrationFailuresNameTheEventsMissing() {
    let failed: Set<String> = [kAXWindowMovedNotification, kAXUIElementDestroyedNotification, "AXSomethingElse"]
    #expect(WindowObservation27.observedEvents(for: failed) == [.moved, .destroyed])
    #expect(WindowObservation27.observedEvents(for: Set(AXObserverHub.notifications)) == [.created, .moved, .resized, .titleChanged, .destroyed])
}

@Test func onlyATimeoutIsWorthOneMoreTryWhenTheAppFinishesLaunching() {
    #expect(WindowObservation27.needsRetry([kAXWindowMovedNotification: .cannotComplete]))
    #expect(WindowObservation27.needsRetry([kAXWindowMovedNotification: .failure, kAXTitleChangedNotification: .cannotComplete]))
    #expect(!WindowObservation27.needsRetry([kAXWindowMovedNotification: .notificationUnsupported]))
    #expect(!WindowObservation27.needsRetry([:]))
}

@Test func anObserverThatCannotBeMadeNamesEveryNotification() {
    // A process that does not exist: AXObserverCreate fails, and each notification carries the error.
    let hub = AXObserverHub()
    let failures = hub.observe(pid: 999_999, bundleID: nil) { _ in }
    #expect(Set(failures.keys) == Set(AXObserverHub.notifications))
    #expect(failures.values.allSatisfy { $0 != .success })
}

// MARK: The launch retry and the claim on a pid

private let launching = AppInfo27(pid: 4242, bundleID: "com.example.Slow", name: "Slow", isHidden: false)
private let timeout: [String: AXError] = [kAXWindowMovedNotification: .cannotComplete]

private final class Counter: Sendable {
    private let value = Mutex(0)
    var count: Int { value.withLock { $0 } }

    /// The count before this call.
    func increment() -> Int {
        value.withLock { count in
            defer { count += 1 }
            return count
        }
    }
}

private final class Flag: Sendable {
    private let value: Mutex<Bool>
    init(_ value: Bool) { self.value = Mutex(value) }
    var isSet: Bool {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}

/// Holds catch-ups until `release()`, which lets every one waiting go; a later one waits again. A
/// held catch-up that is cancelled goes on, so a test's time limit cannot leave one parked.
private final class CatchUpGate: Sendable {
    private struct State {
        var nextID = 0
        var waiting: [(id: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    private let state = Mutex(State())

    var waiterCount: Int { state.withLock { $0.waiting.count } }

    func wait() async {
        let id = state.withLock { state -> Int in
            defer { state.nextID += 1 }
            return state.nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { state in
                    if Task.isCancelled { return true }
                    state.waiting.append((id, continuation))
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let cancelled = state.withLock { state -> CheckedContinuation<Void, Never>? in
                guard let index = state.waiting.firstIndex(where: { $0.id == id }) else { return nil }
                return state.waiting.remove(at: index).continuation
            }
            cancelled?.resume()
        }
    }

    func release() {
        let released = state.withLock { state in
            defer { state.waiting = [] }
            return state.waiting.map(\.continuation)
        }
        for continuation in released { continuation.resume() }
    }

    /// Waits until `count` catch-ups are held, for up to 2 s of wall-clock time.
    func waitForWaiters(_ count: Int) async -> Bool {
        let begun = ContinuousClock.now
        while waiterCount < count {
            if begun.duration(to: .now) > .seconds(2) { return false }
            await Task.yield()
        }
        return true
    }
}

private func windowBox(_ id: UInt32) -> AXElementBox { AXElementBox(AXUIElementCreateApplication(pid_t(id))) }

private let catchUpAttributes = WindowAttributes27(
    role: "AXWindow", subrole: "AXStandardWindow", title: "Doc", frame: CGRect(x: 0, y: 0, width: 100, height: 100),
    canMove: true, canResize: true, minSize: nil, isFullscreen: false, isMinimized: false)

private struct ObservationHarness {
    let observation: WindowObservation27
    let continuation: AsyncStream<PlatformEvent>.Continuation
    var iterator: AsyncStream<PlatformEvent>.Iterator
    let registry = WindowRegistry()
    let registrations: Counter
    let isRunning = Flag(true)
    /// How many catch-ups have started.
    let announcements = Counter()
    let notices = RecordedNotices()

    /// `outcomes` answers each registration in turn and then repeats its last answer. A catch-up
    /// registers the windows `found` names, once `catchUpGate` releases it when there is one.
    init(
        isLaunching: Bool = true, gate: AsyncStream<Void>? = nil, outcomes: [[String: AXError]],
        found: [UInt32] = [], catchUpGate: CatchUpGate? = nil
    ) {
        let (stream, continuation) = AsyncStream<PlatformEvent>.makeStream()
        let registrations = Counter()
        let isRunning = isRunning
        let announcements = announcements
        let axQueue = AXQueue()
        let registry = registry
        observation = WindowObservation27(
            axQueue: axQueue, registry: registry, catalog: WindowCatalog27(registry: registry, axQueue: axQueue),
            events: continuation,
            notices: notices,
            environment: .init(
                isRunning: { _ in isRunning.isSet },
                isLaunching: { _ in isLaunching },
                untilFinishedLaunching: { _ in if let gate { for await _ in gate { break } } },
                register: { _, _, _, _ in
                    let index = registrations.increment()
                    return outcomes[min(index, outcomes.count - 1)]
                },
                windows: { app, announce in
                    _ = announcements.increment()
                    if let catchUpGate { await catchUpGate.wait() }
                    var steps: [WindowObservation27.Found] = []
                    for id in found {
                        let registration = registry.register(
                            windowBox(id), pid: app.pid, windowID: ResolvedWindowID(id: id, by: .privateSymbol))
                        let snapshot = Windows27.snapshot(handle: registration.handle, app: app, attributes: catchUpAttributes)
                        let entry = WindowCatalog27.Entry(snapshot: snapshot, element: windowBox(id), isNew: registration.isNew)
                        steps.append(WindowObservation27.Found(entry: entry, announcement: announce(entry)))
                    }
                    return steps
                }))
        self.continuation = continuation
        self.registrations = registrations
        iterator = stream.makeAsyncIterator()
        observation.begin()
    }

    mutating func next() async -> PlatformEvent? { await iterator.next() }
}

@Test(.timeLimit(.minutes(1)))
func anAppThatQuitDuringTheLaunchWaitIsNeverReportedUnobservable() async {
    let (gate, open) = AsyncStream<Void>.makeStream()
    var harness = ObservationHarness(gate: gate, outcomes: [timeout])
    guard case .retrying(let retry) = await harness.observation.attempt(launching) else {
        Issue.record("expected a retry")
        return
    }
    await harness.observation.appQuit(pid: launching.pid)
    open.yield()
    await retry.bounded()
    harness.continuation.yield(.reconfigurationEnded)
    #expect(await harness.next() == .appQuit(pid: 4242))
    #expect(await harness.next() == .reconfigurationEnded)
    #expect(harness.registrations.count == 1)
}

@Test(.timeLimit(.minutes(1)))
func aNewAppOnTheSamePidIsNotTakenOverByTheOldRetry() async {
    let (gate, open) = AsyncStream<Void>.makeStream()
    var harness = ObservationHarness(gate: gate, outcomes: [timeout, timeout, timeout])
    guard case .retrying(let retry) = await harness.observation.attempt(launching) else {
        Issue.record("expected a retry")
        return
    }
    await harness.observation.appQuit(pid: launching.pid)
    guard case .retrying(let second) = await harness.observation.attempt(launching) else {
        Issue.record("the reused pid is claimed afresh")
        return
    }
    open.yield()
    open.yield()
    await retry.bounded()
    await second.bounded()
    harness.continuation.yield(.reconfigurationEnded)
    #expect(await harness.next() == .appQuit(pid: 4242))
    #expect(await harness.next() == .unobservable(pid: 4242, bundleID: "com.example.Slow", missing: [.moved]))
    #expect(await harness.next() == .reconfigurationEnded)
}

@Test(.timeLimit(.minutes(1)))
func aRetryThatSucceedsReportsNothing() async {
    var harness = ObservationHarness(outcomes: [timeout, [:]])
    guard case .retrying(let retry) = await harness.observation.attempt(launching) else {
        Issue.record("expected a retry")
        return
    }
    await retry.bounded()
    harness.continuation.yield(.reconfigurationEnded)
    #expect(await harness.next() == .reconfigurationEnded)
    #expect(harness.registrations.count == 2)
    #expect(harness.announcements.count == 1)
}

@Test(.timeLimit(.minutes(1)))
func aRetryThatFailsAgainReportsTheAppUnobservable() async {
    var harness = ObservationHarness(outcomes: [timeout])
    guard case .retrying(let retry) = await harness.observation.attempt(launching) else {
        Issue.record("expected a retry")
        return
    }
    await retry.bounded()
    #expect(await harness.next() == .unobservable(pid: 4242, bundleID: "com.example.Slow", missing: [.moved]))
}

@Test func anAppThatIsNotLaunchingIsReportedAtOnceAndNeverRetried() async {
    let harness = ObservationHarness(isLaunching: false, outcomes: [timeout])
    guard case .unobservable(let app) = await harness.observation.attempt(launching) else {
        Issue.record("expected unobservable")
        return
    }
    #expect(app.missing == [.moved])
    #expect(harness.registrations.count == 1)
}

@Test func anAppThatFailedToRegisterIsRegisteredAgainAndObservedWhenTheTransientIsOver() async {
    let harness = ObservationHarness(isLaunching: false, outcomes: [timeout, [:]])
    guard case .unobservable = await harness.observation.attempt(launching) else {
        Issue.record("expected unobservable")
        return
    }
    #expect(await harness.observation.observeAgain(launching) == nil)
    #expect(harness.registrations.count == 2)
    // It holds a claim again: a query does not register it a third time.
    _ = await harness.observation.attempt(launching)
    #expect(harness.registrations.count == 2)
}

@Test func anAppThatFailsAgainIsStillUnobservable() async {
    let harness = ObservationHarness(isLaunching: false, outcomes: [timeout])
    _ = await harness.observation.attempt(launching)
    let again = await harness.observation.observeAgain(launching)
    #expect(again == UnobservableApp(pid: 4242, bundleID: "com.example.Slow", missing: [.moved]))
    #expect(harness.registrations.count == 2)
}

@Test func anAppTheRunNeverClaimedOrThatIsGoneIsNotRegisteredAgain() async {
    let harness = ObservationHarness(isLaunching: false, outcomes: [[:]])
    #expect(await harness.observation.observeAgain(launching) == nil)
    #expect(harness.registrations.count == 0)
    _ = await harness.observation.attempt(launching)
    harness.isRunning.isSet = false
    #expect(await harness.observation.observeAgain(launching) == nil)
    #expect(harness.registrations.count == 1)
}

@Test func anAppIsRegisteredOncePerRunAndNeverForTaflItself() async {
    let harness = ObservationHarness(outcomes: [[:]])
    _ = await harness.observation.attempt(launching)
    _ = await harness.observation.attempt(launching)
    let own = AppInfo27(pid: getpid(), bundleID: nil, name: "Tafl", isHidden: false)
    _ = await harness.observation.attempt(own)
    #expect(harness.registrations.count == 1)
}

@Test func nothingIsRegisteredWhileObservingIsOff() async {
    let harness = ObservationHarness(outcomes: [[:]])
    harness.observation.end()
    _ = await harness.observation.attempt(launching)
    #expect(harness.registrations.count == 0)
}

@Test(.timeLimit(.minutes(1)))
func anAppThatIsGoneButNotYetQuitIsNeitherRegisteredNorReportedWhenTheWaitEnds() async {
    let (gate, open) = AsyncStream<Void>.makeStream()
    var harness = ObservationHarness(gate: gate, outcomes: [timeout])
    guard case .retrying(let retry) = await harness.observation.attempt(launching) else {
        Issue.record("expected a retry")
        return
    }
    // The wait ends because the app terminated, before the quit has been handled: its claim is still held.
    harness.isRunning.isSet = false
    open.yield()
    await retry.bounded()
    harness.continuation.yield(.reconfigurationEnded)
    #expect(await harness.next() == .reconfigurationEnded)
    #expect(harness.registrations.count == 1)
    #expect(harness.announcements.count == 0)
}

@Test(.timeLimit(.minutes(1)))
func aQueryThatMetAnAppBeforeItQuitRegistersAndReportsNothing() async {
    // Not launching: a timeout would otherwise start a retry that races the count below.
    var harness = ObservationHarness(isLaunching: false, outcomes: [timeout])
    harness.isRunning.isSet = false
    await harness.observation.discover(launching)
    harness.continuation.yield(.reconfigurationEnded)
    #expect(await harness.next() == .reconfigurationEnded)
    #expect(harness.registrations.count == 0)

    // Nothing was left claimed: a new app on the same pid is observed.
    harness.isRunning.isSet = true
    _ = await harness.observation.attempt(launching)
    #expect(harness.registrations.count == 1)
}

@Test func aFirstTryThatFailsOnAnAppThatJustQuitIsNotReported() async {
    let flag = Flag(true)
    // The process goes away while its registration is in flight.
    let observation = WindowObservation27(
        axQueue: AXQueue(), registry: WindowRegistry(),
        catalog: WindowCatalog27(registry: WindowRegistry(), axQueue: AXQueue()),
        events: AsyncStream<PlatformEvent>.makeStream().continuation,
        notices: RecordedNotices(),
        environment: .init(
            isRunning: { _ in flag.isSet },
            isLaunching: { _ in false },
            untilFinishedLaunching: { _ in },
            register: { _, _, _, _ in
                flag.isSet = false
                return timeout
            },
            windows: { _, _ in [] }))
    observation.begin()
    guard case .observed = await observation.attempt(launching) else {
        Issue.record("a quit app must not be reported")
        return
    }
}

// MARK: Catch-up

private let foundWindow = WindowHandle(pid: 4242, windowID: 5001, isStable: true)

@Test(.timeLimit(.minutes(1)))
func aLaunchMissingOnlyTitleChangesStillAnnouncesItsWindows() async {
    var harness = ObservationHarness(
        isLaunching: false, outcomes: [[kAXTitleChangedNotification: .notificationUnsupported]], found: [5001])
    await harness.observation.appLaunched(launching)
    harness.continuation.yield(.reconfigurationEnded)
    #expect(await harness.next() == .appLaunched(pid: 4242, bundleID: "com.example.Slow"))
    guard case .windowCreated(let snapshot)? = await harness.next() else {
        Issue.record("expected the catch-up to announce the window")
        return
    }
    #expect(snapshot.handle == foundWindow)
    #expect(await harness.next() == .unobservable(pid: 4242, bundleID: "com.example.Slow", missing: [.titleChanged]))
    #expect(await harness.next() == .reconfigurationEnded)
    #expect(harness.notices.all == [.announced(foundWindow)])
}

@Test(.timeLimit(.minutes(1)))
func aCatchUpAnnouncesAWindowAQueryRegisteredFirst() async {
    var harness = ObservationHarness(isLaunching: false, outcomes: [[:]], found: [5001])
    _ = harness.registry.register(windowBox(5001), pid: 4242, windowID: ResolvedWindowID(id: 5001, by: .privateSymbol))
    await harness.observation.appLaunched(launching)
    harness.continuation.yield(.reconfigurationEnded)
    #expect(await harness.next() == .appLaunched(pid: 4242, bundleID: "com.example.Slow"))
    guard case .windowCreated(let snapshot)? = await harness.next() else {
        Issue.record("expected the catch-up to announce the window the query registered")
        return
    }
    #expect(snapshot.handle == foundWindow)
    #expect(await harness.next() == .reconfigurationEnded)
}

/// A window's end is its destruction or its app's quit, never a failed read: the quit takes every
/// registration of the app and tells the notices and the core.
@Test(.timeLimit(.minutes(1)))
func anAppsQuitEndsItsRegisteredWindows() async {
    var harness = ObservationHarness(isLaunching: false, outcomes: [[:]])
    let window = harness.registry.handle(
        for: windowBox(5001), pid: 4242, windowID: ResolvedWindowID(id: 5001, by: .privateSymbol))
    await harness.observation.appQuit(pid: 4242)
    #expect(await harness.next() == .appQuit(pid: 4242))
    #expect(harness.registry.element(for: window) == nil)
    #expect(harness.notices.all == [.quit(4242)])
}

@Test(.timeLimit(.minutes(1)))
func aCatchUpForAnAppThatQuitMeanwhilePublishesAndKeepsNothing() async {
    let gate = CatchUpGate()
    var harness = ObservationHarness(isLaunching: false, outcomes: [[:]], found: [5001], catchUpGate: gate)
    let observation = harness.observation
    let launch = Task { await observation.appLaunched(launching) }
    #expect(await gate.waitForWaiters(1))
    harness.isRunning.isSet = false
    await observation.appQuit(pid: 4242)
    gate.release()
    await launch.bounded()
    harness.continuation.yield(.reconfigurationEnded)
    #expect(await harness.next() == .appLaunched(pid: 4242, bundleID: "com.example.Slow"))
    #expect(await harness.next() == .appQuit(pid: 4242))
    #expect(await harness.next() == .reconfigurationEnded)
    #expect(harness.registry.knownHandle(of: windowBox(5001)) == nil)
    // Nothing found under the ended claim was announced; the quit reached the notices.
    #expect(harness.notices.all == [.quit(4242)])
}

@Test(.timeLimit(.minutes(1)))
func aCatchUpOvertakenByARestartLeavesItsWindowsToTheNewRun() async {
    let gate = CatchUpGate()
    var harness = ObservationHarness(isLaunching: false, outcomes: [[:]], found: [5001], catchUpGate: gate)
    let observation = harness.observation
    let launch = Task { await observation.appLaunched(launching) }
    #expect(await gate.waitForWaiters(1))
    observation.end()
    observation.begin()
    gate.release()
    await launch.bounded()
    // The stale catch-up published nothing and withdrew nothing: the app still runs.
    #expect(harness.registry.knownHandle(of: windowBox(5001)) == foundWindow)
    // The new run observes the app, adopts the window and owes it its announcement still.
    let observing = Task { await observation.attempt(launching) }
    #expect(await gate.waitForWaiters(1))
    gate.release()
    _ = await observing.bounded()
    harness.continuation.yield(.reconfigurationEnded)
    #expect(await harness.next() == .appLaunched(pid: 4242, bundleID: "com.example.Slow"))
    guard case .windowCreated(let snapshot)? = await harness.next() else {
        Issue.record("expected the new run to announce the window once")
        return
    }
    #expect(snapshot.handle == foundWindow)
    #expect(await harness.next() == .reconfigurationEnded)
}

@Test(.timeLimit(.minutes(1)))
func aLaunchAQueryMetFirstStillAnnouncesItsWindows() async {
    var harness = ObservationHarness(isLaunching: false, outcomes: [[:]], found: [5001])
    // A query claims and registers the app before its launch is handled.
    await harness.observation.discover(launching)
    await harness.observation.appLaunched(launching)
    harness.continuation.yield(.reconfigurationEnded)
    #expect(await harness.next() == .appLaunched(pid: 4242, bundleID: "com.example.Slow"))
    guard case .windowCreated(let snapshot)? = await harness.next() else {
        Issue.record("expected the launch's catch-up to announce the window")
        return
    }
    #expect(snapshot.handle == foundWindow)
    #expect(await harness.next() == .reconfigurationEnded)
    #expect(harness.registrations.count == 1)
}

/// Reads any element as a standard window whose id is the pid the element was made from.
private let echoReader = WindowReader27(
    readTracked: { element, _, _, then in
        let id = UInt32(AXWindowAccess.pid(element.element) ?? 0)
        return then(ElementRead(element: element, attributes: catchUpAttributes, windowID: ResolvedWindowID(id: id, by: .privateSymbol)))
    },
    title: { _, _ in "Doc" },
    app: { pid in AppInfo27(pid: pid, bundleID: "com.example.Slow", name: "Slow", isHidden: false) },
    afterReads: { _, work in work() })

private func createdEvent(_ id: UInt32) -> AXObserverHub.Event {
    AXObserverHub.Event(pid: 4242, bundleID: nil, notification: kAXWindowCreatedNotification, element: windowBox(id).element)
}

private func movedEvent(_ id: UInt32) -> AXObserverHub.Event {
    AXObserverHub.Event(pid: 4242, bundleID: nil, notification: kAXWindowMovedNotification, element: windowBox(id).element)
}

@Test(.timeLimit(.minutes(1)))
func aWindowTheCatchUpAnnouncedFirstIsNotAnnouncedAgainByItsCreation() async {
    var harness = ObservationHarness(isLaunching: false, outcomes: [[:]], found: [5001])
    let (stream, continuation) = AsyncStream<PlatformEvent>.makeStream()
    let translator = WindowEventTranslator(registry: harness.registry, reader: echoReader, events: continuation, notices: harness.notices)
    var translated = stream.makeAsyncIterator()
    await harness.observation.appLaunched(launching)
    translator.enqueue(createdEvent(5001))
    translator.enqueue(movedEvent(5001))
    #expect(await translated.next() == .windowMoved(foundWindow))
    #expect(await harness.next() == .appLaunched(pid: 4242, bundleID: "com.example.Slow"))
    guard case .windowCreated? = await harness.next() else {
        Issue.record("expected the catch-up to announce the window")
        return
    }
    translator.closeAll()
}

@Test(.timeLimit(.minutes(1)))
func aWindowItsCreationAnnouncedFirstIsNotAnnouncedAgainByTheCatchUp() async {
    var harness = ObservationHarness(isLaunching: false, outcomes: [[:]], found: [5001])
    let (stream, continuation) = AsyncStream<PlatformEvent>.makeStream()
    let translator = WindowEventTranslator(registry: harness.registry, reader: echoReader, events: continuation, notices: harness.notices)
    var translated = stream.makeAsyncIterator()
    translator.enqueue(createdEvent(5001))
    guard case .windowCreated? = await translated.next() else {
        Issue.record("expected the creation to be announced")
        return
    }
    await harness.observation.appLaunched(launching)
    harness.continuation.yield(.reconfigurationEnded)
    #expect(await harness.next() == .appLaunched(pid: 4242, bundleID: "com.example.Slow"))
    #expect(await harness.next() == .reconfigurationEnded)
    translator.closeAll()
}

// MARK: Announcing is one step

@Test(.timeLimit(.minutes(1)))
func aCatchUpOvertakenByARestartAfterItsEnumerationLeavesExactlyOneAnnouncement() async {
    let gate = CatchUpGate()
    var harness = ObservationHarness(isLaunching: false, outcomes: [[:]], found: [5001], catchUpGate: gate)
    let observation = harness.observation
    // The launch's catch-up has enumerated; its claim is checked only in the announcing step.
    let launch = Task { await observation.appLaunched(launching) }
    #expect(await gate.waitForWaiters(1))
    observation.end()
    observation.begin()
    let observing = Task { await observation.attempt(launching) }
    #expect(await gate.waitForWaiters(2))
    // The stale catch-up and the new run's go on together; only the new claim's step announces.
    gate.release()
    await launch.bounded()
    _ = await observing.bounded()
    harness.continuation.yield(.reconfigurationEnded)
    #expect(await harness.next() == .appLaunched(pid: 4242, bundleID: "com.example.Slow"))
    guard case .windowCreated(let snapshot)? = await harness.next() else {
        Issue.record("expected the window to be announced")
        return
    }
    #expect(snapshot.handle == foundWindow)
    #expect(await harness.next() == .reconfigurationEnded)
    // The mark stays: the window's own creation notification announces nothing more.
    let (stream, continuation) = AsyncStream<PlatformEvent>.makeStream()
    let translator = WindowEventTranslator(registry: harness.registry, reader: echoReader, events: continuation, notices: harness.notices)
    var translated = stream.makeAsyncIterator()
    translator.enqueue(createdEvent(5001))
    translator.enqueue(movedEvent(5001))
    #expect(await translated.next() == .windowMoved(foundWindow))
    translator.closeAll()
}

@Test(.timeLimit(.minutes(1)))
func twoCatchUpsRacingOnOneWindowAnnounceItOnce() async {
    let gate = CatchUpGate()
    var harness = ObservationHarness(isLaunching: false, outcomes: [[:]], found: [5001], catchUpGate: gate)
    let observation = harness.observation
    // A query observes the app; two launch notifications then each owe and start a catch-up under its claim.
    await observation.discover(launching)
    let first = Task { await observation.appLaunched(launching) }
    let second = Task { await observation.appLaunched(launching) }
    #expect(await gate.waitForWaiters(2))
    gate.release()
    await first.bounded()
    await second.bounded()
    harness.continuation.yield(.reconfigurationEnded)
    var created = 0
    while let event = await harness.next(), event != .reconfigurationEnded {
        if case .windowCreated = event { created += 1 }
    }
    #expect(created == 1)
    #expect(harness.notices.all == [.announced(foundWindow)])
}
