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

// MARK: The claim on a pid, and the tries after a failed registration

private let launching = AppInfo27(pid: 4242, bundleID: "com.example.Slow", name: "Slow", isHidden: false)
private let other = AppInfo27(pid: 4343, bundleID: "com.example.Other", name: "Other", isHidden: false)
private let timeout: [String: AXError] = [kAXWindowMovedNotification: .cannotComplete]
/// Calendar while it launches: every notification refused.
private let refused = Dictionary(uniqueKeysWithValues: AXObserverHub.notifications.map { ($0, AXError.cannotComplete) })
private let everyEvent: Set<ObservedEvent> = [.created, .moved, .resized, .titleChanged, .destroyed]
private let retryDelays: [Duration] = [.seconds(3), .seconds(10)]

/// The outcome event a registration of `app` publishes.
private func outcome(_ missing: Set<ObservedEvent>, retrying: Bool = false, of app: AppInfo27 = launching) -> PlatformEvent {
    .observability(pid: app.pid, bundleID: app.bundleID, missing: missing, retrying: retrying)
}

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

/// The platform's waits before its tries, each held until the test lets it go. A wait whose try is
/// cancelled, because its claim ended, ends at once and throws, as the clock's sleep does. Once the
/// test's scope opens its gates, every wait, later ones too, ends at once, so tries left running finish.
private final class HeldWaits: Sendable {
    private struct Wait {
        let delay: Duration
        let gate: Gate
    }

    private struct State {
        var waits: [Wait] = []
        var isReleased = false
    }

    private let state = Mutex(State())
    private let cancelled = Tally()

    init() {
        GateScope.current?.onOpen { [self] in releaseAll() }
    }

    /// What each wait asked for, in order.
    var delays: [Duration] { state.withLock { $0.waits.map(\.delay) } }

    func sleep(for delay: Duration) async throws {
        let gate = Gate()
        let released = state.withLock { state -> Bool in
            state.waits.append(Wait(delay: delay, gate: gate))
            return state.isReleased
        }
        if released { gate.open() }
        await withTaskCancellationHandler {
            await gate.hold()
        } onCancel: {
            cancelled.increment()
            gate.open()
        }
        try Task.checkCancellation()
    }

    func waitForWaits(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
        await waitUntil("\(count) waits before a try", sourceLocation: sourceLocation) { state.withLock { $0.waits.count } >= count }
    }

    /// Lets the wait with this index go, counted from 0.
    func release(_ index: Int, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let gate = state.withLock({ index < $0.waits.count ? $0.waits[index].gate : nil }) else {
            Issue.record("No wait \(index) to let go", sourceLocation: sourceLocation)
            return
        }
        gate.open()
    }

    func waitForCancelled(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
        await cancelled.wait(for: count, "cancelled waits", sourceLocation: sourceLocation)
    }

    private func releaseAll() {
        let gates = state.withLock { state -> [Gate] in
            state.isReleased = true
            return state.waits.map(\.gate)
        }
        gates.forEach { $0.open() }
    }
}

/// The handler each registration was given, in order: a test delivers a notification through it as
/// the hub would for that registration.
private final class Handlers: Sendable {
    private let all = Mutex<[AXObserverHub.Handler]>([])

    func append(_ handler: @escaping AXObserverHub.Handler) {
        all.withLock { $0.append(handler) }
    }

    /// Delivers the notification through the handler of the registration with this index, counted from 0.
    func deliver(_ event: AXObserverHub.Event, through index: Int) {
        all.withLock { $0[index] }(event)
    }
}

private func windowBox(_ id: UInt32) -> AXElementBox { AXElementBox(AXUIElementCreateApplication(pid_t(id))) }

private let catchUpAttributes = WindowAttributes27(
    role: "AXWindow", subrole: "AXStandardWindow", title: "Doc", frame: CGRect(x: 0, y: 0, width: 100, height: 100),
    canMove: true, canResize: true, minSize: nil, isFullscreen: false, isMinimized: false)

/// Reads any element as a standard window whose id is the pid the element was made from.
private let echoReader = WindowReader27(
    readTracked: { element, _, _, then in
        let id = UInt32(AXWindowAccess.pid(element.element) ?? 0)
        return then(ElementRead(element: element, attributes: catchUpAttributes, windowID: ResolvedWindowID(id: id, by: .privateSymbol)))
    },
    title: { _, _ in "Doc" },
    app: { pid in AppInfo27(pid: pid, bundleID: "com.example.Slow", name: "Slow", isHidden: false) },
    afterReads: { _, work in work() })

private func notification(_ name: String, _ id: UInt32) -> AXObserverHub.Event {
    AXObserverHub.Event(pid: 4242, bundleID: nil, notification: name, element: windowBox(id).element)
}

private struct ObservationHarness {
    let observation: WindowObservation27
    let continuation: AsyncStream<PlatformEvent>.Continuation
    let events: Collector<PlatformEvent>
    let registry = WindowRegistry()
    let registrations: Counter
    let isRunning = Flag(true)
    /// How many catch-ups have started.
    let announcements = Counter()
    /// How many times the registration for a pid was taken back.
    let stops = Counter()
    let notices = RecordedNotices()
    let waits = HeldWaits()
    let handlers = Handlers()

    /// `outcomes` answers each registration, of any app, in turn and then repeats its last answer;
    /// `held` holds each registration on its app's queue until it opens. Only `launching` is ever still
    /// launching, and only when `isLaunching`: its wait to finish is held at `gate` when there is one. A
    /// catch-up registers the windows `found` names, once `catchUpGate` releases it when there is one.
    /// A failed launch or query is tried again at `retryDelays`, each wait held in `waits`.
    init(
        isLaunching: Bool = true, gate: Gate? = nil, outcomes: [[String: AXError]],
        found: [UInt32] = [], catchUpGate: Gate? = nil, held: ThreadGate? = nil, retryDelays: [Duration] = []
    ) {
        let (stream, continuation) = AsyncStream<PlatformEvent>.makeStream()
        let registrations = Counter()
        let isRunning = isRunning
        let announcements = announcements
        let stops = stops
        let waits = waits
        let handlers = handlers
        let axQueue = AXQueue()
        let registry = registry
        observation = WindowObservation27(
            axQueue: axQueue, registry: registry,
            events: continuation,
            notices: notices,
            retryDelays: retryDelays,
            environment: .init(
                isRunning: { _ in isRunning.isSet },
                isLaunching: { pid in isLaunching && pid == launching.pid },
                untilFinishedLaunching: { _ in await gate?.hold() },
                register: { _, _, _, handler in
                    handlers.append(handler)
                    let index = registrations.increment()
                    held?.hold()
                    return outcomes[min(index, outcomes.count - 1)]
                },
                stop: { _, _ in _ = stops.increment() },
                windows: { app, announce in
                    _ = announcements.increment()
                    await catchUpGate?.hold()
                    var steps: [WindowObservation27.Found] = []
                    for id in found {
                        let registration = registry.register(
                            windowBox(id), pid: app.pid, windowID: ResolvedWindowID(id: id, by: .privateSymbol))
                        let snapshot = Windows27.snapshot(handle: registration.handle, app: app, attributes: catchUpAttributes)
                        let entry = WindowCatalog27.Entry(snapshot: snapshot, element: windowBox(id), isNew: registration.isNew)
                        steps.append(WindowObservation27.Found(entry: entry, announcement: announce(entry)))
                    }
                    return steps
                },
                reader: echoReader,
                sleep: { try await waits.sleep(for: $0) }))
        self.continuation = continuation
        self.registrations = registrations
        events = Collector(stream)
        observation.begin()
    }

    func next(sourceLocation: SourceLocation = #_sourceLocation) async -> PlatformEvent? {
        await events.next(sourceLocation: sourceLocation)
    }

    /// The events published up to now, each expected in turn, then nothing more.
    func expectEvents(_ expected: [PlatformEvent], sourceLocation: SourceLocation = #_sourceLocation) async {
        continuation.yield(.reconfigurationEnded)
        for event in expected + [.reconfigurationEnded] {
            #expect(await next(sourceLocation: sourceLocation) == event, sourceLocation: sourceLocation)
        }
    }
}

@Test(.gated, .timeLimit(.minutes(1)))
func anAppThatQuitDuringTheLaunchWaitIsNeverReportedAgain() async {
    let gate = Gate()
    let harness = ObservationHarness(gate: gate, outcomes: [timeout, [:]], found: [5001])
    #expect(await harness.observation.observe(launching, as: .restart) == UnobservableApp(pid: 4242, bundleID: "com.example.Slow", missing: [.moved]))
    let tries = harness.observation.tries(of: 4242)
    await harness.observation.appQuit(pid: launching.pid)
    gate.open()
    await tries?.bounded()
    // The claim ended while the launch wait held: nothing is published, and nothing is logged as observed.
    await harness.expectEvents([outcome([.moved], retrying: true), .appQuit(pid: 4242)])
    #expect(harness.registrations.count == 1)
    // Nor does the ended wait leave its windows owed: a query that meets a new process on the pid
    // announces nothing.
    await harness.observation.discover(launching)
    await harness.expectEvents([outcome([])])
    #expect(harness.announcements.count == 0)
}

@Test(.gated, .timeLimit(.minutes(1)))
func aNewAppOnTheSamePidIsNotTakenOverByTheOldRetry() async {
    let gate = Gate()
    let harness = ObservationHarness(gate: gate, outcomes: [timeout, timeout, timeout])
    _ = await harness.observation.observe(launching, as: .restart)
    let first = harness.observation.tries(of: 4242)
    await harness.observation.appQuit(pid: launching.pid)
    _ = await harness.observation.observe(launching, as: .restart)
    let second = harness.observation.tries(of: 4242)
    #expect(second != nil && second != first)
    gate.open()
    await first?.bounded()
    await second?.bounded()
    await harness.expectEvents([
        outcome([.moved], retrying: true), .appQuit(pid: 4242),
        outcome([.moved], retrying: true), outcome([.moved]),
    ])
    #expect(harness.registrations.count == 3)
}

@Test(.timeLimit(.minutes(1)))
func aRegistrationOnceTheAppHasFinishedLaunchingPublishesItObserved() async {
    let harness = ObservationHarness(outcomes: [timeout, [:]])
    _ = await harness.observation.observe(launching, as: .restart)
    await harness.observation.tries(of: 4242)?.bounded()
    await harness.expectEvents([outcome([.moved], retrying: true), outcome([])])
    #expect(harness.registrations.count == 2)
    #expect(harness.announcements.count == 1)
}

@Test(.timeLimit(.minutes(1)))
func aRegistrationOnceTheAppHasFinishedLaunchingThatFailsPublishesItUnobservable() async {
    let harness = ObservationHarness(outcomes: [timeout])
    _ = await harness.observation.observe(launching, as: .restart)
    await harness.observation.tries(of: 4242)?.bounded()
    await harness.expectEvents([outcome([.moved], retrying: true), outcome([.moved])])
}

/// A start's or a restart's registration of an app that is not launching has no tries of the platform's:
/// a restart's own retries cover it.
@Test(arguments: [ObservingRun.start, .restart])
func aRegistrationAtStartOrRestartOfAnAppNotLaunchingIsReportedAtOnceAndNeverRetried(run: ObservingRun) async {
    let harness = ObservationHarness(isLaunching: false, outcomes: [timeout], retryDelays: retryDelays)
    let app = await harness.observation.observe(launching, as: run)
    #expect(app?.missing == [.moved])
    #expect(harness.registrations.count == 1)
    #expect(harness.observation.tries(of: 4242) == nil)
    await harness.expectEvents([outcome([.moved])])
}

/// An app still launching when Tafl starts is met as its launch: refused when it has finished launching,
/// it is tried 3 s later, and the registration that observes announces its launch windows after its outcome.
@Test(.gated, .timeLimit(.minutes(1)))
func anAppStillLaunchingWhenTaflStartsIsMetAsItsLaunch() async {
    let harness = ObservationHarness(outcomes: [refused, refused, [:]], found: [5001], retryDelays: retryDelays)
    let app = await harness.observation.observe(launching, as: .start)
    #expect(app?.missing == everyEvent)
    let tries = harness.observation.tries(of: 4242)
    await harness.waits.waitForWaits(1)
    #expect(harness.waits.delays == [.seconds(3)])
    harness.waits.release(0)
    await tries?.bounded()
    await harness.expectEvents([
        outcome(everyEvent, retrying: true), outcome(everyEvent, retrying: true), outcome([]),
        .windowCreated(Windows27.snapshot(handle: foundWindow, app: launching, attributes: catchUpAttributes)),
    ])
    #expect(harness.registrations.count == 3)
    #expect(harness.notices.all == [.announced(foundWindow)])
}

/// A restart's registration of an app still launching is tried once when it has finished, and leaves a
/// failure then to the restart's own tries.
@Test(.timeLimit(.minutes(1)))
func aRestartsRegistrationOfAnAppStillLaunchingGetsNoLaunchTries() async {
    let harness = ObservationHarness(outcomes: [refused, refused, [:]], found: [5001], retryDelays: retryDelays)
    _ = await harness.observation.observe(launching, as: .restart)
    await harness.observation.tries(of: 4242)?.bounded()
    await harness.expectEvents([outcome(everyEvent, retrying: true), outcome(everyEvent)])
    #expect(harness.waits.delays.isEmpty)
    #expect(harness.registrations.count == 2)
}

@Test func anAppThatFailedToRegisterIsRegisteredAgainAndObservedWhenTheTransientIsOver() async {
    let harness = ObservationHarness(isLaunching: false, outcomes: [timeout, [:]])
    #expect(await harness.observation.observe(launching, as: .restart) != nil)
    #expect(await harness.observation.observeAgain(launching) == nil)
    #expect(harness.registrations.count == 2)
    // It holds a claim again: a query does not register it a third time.
    await harness.observation.discover(launching)
    #expect(harness.registrations.count == 2)
    await harness.expectEvents([outcome([.moved]), outcome([])])
}

/// A try on an app still launching holds up nothing: it answers with its own registration's failure at
/// once, and the registration once the app has finished launching publishes what it finds. The claim it
/// replaced makes no registration when its own wait ends.
@Test(.gated, .timeLimit(.minutes(1)))
func aTryOnAnAppStillLaunchingAnswersAtOnceAndItsRegistrationOnceLaunchedPublishesTheRest() async {
    let gate = Gate()
    let harness = ObservationHarness(gate: gate, outcomes: [timeout, timeout, [:]], found: [5001])
    _ = await harness.observation.observe(launching, as: .restart)
    let replaced = harness.observation.tries(of: 4242)
    let observation = harness.observation
    let again = await Task { await observation.observeAgain(launching) }.bounded()
    #expect(again == .some(UnobservableApp(pid: 4242, bundleID: "com.example.Slow", missing: [.moved])))
    await gate.waitUntilHolding(2)
    let tries = harness.observation.tries(of: 4242)
    gate.open()
    await replaced?.bounded()
    await tries?.bounded()
    await harness.expectEvents([
        outcome([.moved], retrying: true), outcome([.moved], retrying: true), outcome([]),
        .windowCreated(Windows27.snapshot(handle: foundWindow, app: launching, attributes: catchUpAttributes)),
    ])
    #expect(harness.registrations.count == 3)
    #expect(harness.notices.all == [.announced(foundWindow)])
}

@Test func anAppThatFailsAgainIsStillUnobservable() async {
    let harness = ObservationHarness(isLaunching: false, outcomes: [timeout])
    _ = await harness.observation.observe(launching, as: .restart)
    let again = await harness.observation.observeAgain(launching)
    #expect(again == UnobservableApp(pid: 4242, bundleID: "com.example.Slow", missing: [.moved]))
    #expect(harness.registrations.count == 2)
}

@Test func anAppTheRunNeverClaimedOrThatIsGoneIsNotRegisteredAgain() async {
    let harness = ObservationHarness(isLaunching: false, outcomes: [[:]])
    #expect(await harness.observation.observeAgain(launching) == nil)
    #expect(harness.registrations.count == 0)
    _ = await harness.observation.observe(launching, as: .restart)
    harness.isRunning.isSet = false
    #expect(await harness.observation.observeAgain(launching) == nil)
    #expect(harness.registrations.count == 1)
}

@Test func anAppThatQuitsBeforeItIsRegisteredAgainLeavesNoRegistrationAndNoClaim() async {
    let harness = ObservationHarness(isLaunching: false, outcomes: [timeout, [:]])
    _ = await harness.observation.observe(launching, as: .restart)
    // The app is gone, and its quit has not been handled: isRunning is the first to know.
    harness.isRunning.isSet = false
    #expect(await harness.observation.observeAgain(launching) == nil)
    #expect(harness.registrations.count == 1)
    #expect(harness.stops.count == 1)
    // The claim went with it: a process that takes the pid is registered afresh.
    harness.isRunning.isSet = true
    _ = await harness.observation.observe(launching, as: .restart)
    #expect(harness.registrations.count == 2)
}

@Test func aSuccessfulRegistrationAgainKeepsItsRegistration() async {
    let harness = ObservationHarness(isLaunching: false, outcomes: [timeout, [:]])
    _ = await harness.observation.observe(launching, as: .restart)
    #expect(await harness.observation.observeAgain(launching) == nil)
    #expect(harness.registrations.count == 2)
    #expect(harness.stops.count == 0)
}

@Test func anAppIsRegisteredOncePerRunAndNeverForTaflItself() async {
    let harness = ObservationHarness(outcomes: [[:]])
    _ = await harness.observation.observe(launching, as: .restart)
    _ = await harness.observation.observe(launching, as: .restart)
    let own = AppInfo27(pid: getpid(), bundleID: nil, name: "Tafl", isHidden: false)
    _ = await harness.observation.observe(own, as: .restart)
    #expect(harness.registrations.count == 1)
}

@Test func nothingIsRegisteredWhileObservingIsOff() async {
    let harness = ObservationHarness(outcomes: [[:]])
    harness.observation.end()
    _ = await harness.observation.observe(launching, as: .restart)
    #expect(harness.registrations.count == 0)
}

@Test(.gated, .timeLimit(.minutes(1)))
func anAppThatIsGoneButNotYetQuitIsNeitherRegisteredNorReportedWhenTheWaitEnds() async {
    let gate = Gate()
    let harness = ObservationHarness(gate: gate, outcomes: [timeout])
    _ = await harness.observation.observe(launching, as: .restart)
    let tries = harness.observation.tries(of: 4242)
    // The wait ends because the app terminated, before the quit has been handled: its claim is still held.
    harness.isRunning.isSet = false
    gate.open()
    await tries?.bounded()
    await harness.expectEvents([outcome([.moved], retrying: true)])
    #expect(harness.registrations.count == 1)
    #expect(harness.announcements.count == 0)
}

@Test(.timeLimit(.minutes(1)))
func aQueryThatMetAnAppBeforeItQuitRegistersAndReportsNothing() async {
    let harness = ObservationHarness(isLaunching: false, outcomes: [timeout], retryDelays: retryDelays)
    harness.isRunning.isSet = false
    await harness.observation.discover(launching)
    await harness.expectEvents([])
    #expect(harness.registrations.count == 0)

    // Nothing was left claimed: a new app on the same pid is observed.
    harness.isRunning.isSet = true
    _ = await harness.observation.observe(launching, as: .restart)
    #expect(harness.registrations.count == 1)
}

@Test(.timeLimit(.minutes(1)))
func aFirstTryThatFailsOnAnAppThatJustQuitIsNotReported() async {
    let flag = Flag(true)
    let (stream, continuation) = AsyncStream<PlatformEvent>.makeStream()
    let events = Collector(stream)
    // The process goes away while its registration is in flight.
    let observation = WindowObservation27(
        axQueue: AXQueue(), registry: WindowRegistry(),
        events: continuation,
        notices: RecordedNotices(),
        retryDelays: retryDelays,
        environment: .init(
            isRunning: { _ in flag.isSet },
            isLaunching: { _ in false },
            untilFinishedLaunching: { _ in },
            register: { _, _, _, _ in
                flag.isSet = false
                return timeout
            },
            windows: { _, _ in [] },
            reader: echoReader,
            sleep: { _ in }))
    observation.begin()
    await observation.discover(launching)
    #expect(observation.tries(of: 4242) == nil)
    continuation.yield(.reconfigurationEnded)
    #expect(await events.next() == .reconfigurationEnded)
}

// MARK: The tries after a failed launch or a query's first meeting

/// Calendar on macOS 27.2: every registration is refused until about 0.8 s after launch, after the app
/// has finished launching. The launch is tried again 3 s after that failure, and the registration that
/// observes publishes its outcome before the launch's windows, which it announces.
@Test(.gated, .timeLimit(.minutes(1)))
func aLaunchRefusedUntilAfterItFinishedLaunchingIsTriedAgainAndAnnouncesItsWindowsAfterItsOutcome() async {
    let harness = ObservationHarness(outcomes: [refused, refused, [:]], found: [5001], retryDelays: retryDelays)
    await harness.observation.appLaunched(launching)
    let tries = harness.observation.tries(of: 4242)
    await harness.waits.waitForWaits(1)
    #expect(harness.waits.delays == [.seconds(3)])
    harness.waits.release(0)
    await tries?.bounded()
    await harness.expectEvents([
        .appLaunched(pid: 4242, bundleID: "com.example.Slow"),
        outcome(everyEvent, retrying: true), outcome(everyEvent, retrying: true), outcome([]),
        .windowCreated(Windows27.snapshot(handle: foundWindow, app: launching, attributes: catchUpAttributes)),
    ])
    // The registration that observed ended the tries.
    #expect(harness.waits.delays == [.seconds(3)])
    #expect(harness.registrations.count == 3)
    #expect(harness.notices.all == [.announced(foundWindow)])
}

@Test(.gated, .timeLimit(.minutes(1)))
func aLaunchStillRefusedAtTheLastTryStaysUnobservableAndIsNotTriedAgain() async {
    let harness = ObservationHarness(isLaunching: false, outcomes: [timeout], retryDelays: retryDelays)
    await harness.observation.appLaunched(launching)
    let tries = harness.observation.tries(of: 4242)
    await harness.waits.waitForWaits(1)
    harness.waits.release(0)
    await harness.waits.waitForWaits(2)
    harness.waits.release(1)
    await tries?.bounded()
    // 3 s and 10 s after the launch's failure.
    #expect(harness.waits.delays == [.seconds(3), .seconds(7)])
    await harness.expectEvents([
        .appLaunched(pid: 4242, bundleID: "com.example.Slow"),
        outcome([.moved], retrying: true), outcome([.moved], retrying: true), outcome([.moved]),
    ])
    #expect(harness.registrations.count == 3)
}

@Test(.gated, .timeLimit(.minutes(1)))
func anAppsQuitEndsTheTriesOfAQuerysFirstMeeting() async {
    let harness = ObservationHarness(isLaunching: false, outcomes: [timeout], retryDelays: retryDelays)
    await harness.observation.discover(launching)
    let tries = harness.observation.tries(of: 4242)
    await harness.waits.waitForWaits(1)
    await harness.observation.appQuit(pid: 4242)
    await harness.waits.waitForCancelled(1)
    await tries?.bounded()
    await harness.expectEvents([outcome([.moved], retrying: true), .appQuit(pid: 4242)])
    #expect(harness.registrations.count == 1)
}

/// Whether met at Tafl's start while still launching or at a launch, an app's tries end with the run.
@Test(.gated, .timeLimit(.minutes(1)))
func aRestartEndsTheTriesOfEveryClaim() async {
    let harness = ObservationHarness(outcomes: [timeout], retryDelays: retryDelays)
    _ = await harness.observation.observe(launching, as: .start)
    await harness.observation.appLaunched(other)
    await harness.waits.waitForWaits(2)
    harness.observation.end()
    harness.observation.begin()
    await harness.waits.waitForCancelled(2)
    #expect(harness.observation.tries(of: launching.pid) == nil)
    #expect(harness.observation.tries(of: other.pid) == nil)
    // The start's registration, its try once launched, and the launch's registration.
    #expect(harness.registrations.count == 3)
}

@Test(.gated, .timeLimit(.minutes(1)))
func aRegistrationAskedForAgainEndsTheTriesOfTheClaimItReplaces() async {
    let harness = ObservationHarness(isLaunching: false, outcomes: [timeout, [:]], retryDelays: retryDelays)
    await harness.observation.appLaunched(launching)
    let replaced = harness.observation.tries(of: 4242)
    await harness.waits.waitForWaits(1)
    #expect(await harness.observation.observeAgain(launching) == nil)
    await harness.waits.waitForCancelled(1)
    await replaced?.bounded()
    await harness.expectEvents([
        .appLaunched(pid: 4242, bundleID: "com.example.Slow"), outcome([.moved], retrying: true), outcome([]),
    ])
    #expect(harness.registrations.count == 2)
}

/// Each app's tries run on their own: one held in its launch wait, as at Tafl's start, holds up no other app's.
@Test(.gated, .timeLimit(.minutes(1)))
func oneAppStillLaunchingHoldsUpNoOtherAppsTries() async {
    let gate = Gate()
    let harness = ObservationHarness(gate: gate, outcomes: [timeout], retryDelays: retryDelays)
    _ = await harness.observation.observe(launching, as: .start)
    await harness.observation.appLaunched(other)
    let tries = harness.observation.tries(of: other.pid)
    await harness.waits.waitForWaits(1)
    harness.waits.release(0)
    await harness.waits.waitForWaits(2)
    harness.waits.release(1)
    await tries?.bounded()
    #expect(gate.heldCount == 1)
    await harness.expectEvents([
        outcome([.moved], retrying: true),
        .appLaunched(pid: 4343, bundleID: "com.example.Other"), outcome([.moved], retrying: true, of: other),
        outcome([.moved], retrying: true, of: other), outcome([.moved], of: other),
    ])
    harness.observation.end()
}

@Test(.gated, .timeLimit(.minutes(1)))
func anOutcomeARegistrationFindsAfterItsClaimEndedIsNotPublished() async {
    let held = ThreadGate()
    let harness = ObservationHarness(isLaunching: false, outcomes: [[:]], held: held)
    let observation = harness.observation
    let registering = Task { await observation.observe(launching, as: .restart) }
    await waitUntil("the registration to be in flight") { harness.registrations.count == 1 }
    // The quit ends the claim at once; its own work on the app's queue waits behind the registration.
    let quitting = Task { await observation.appQuit(pid: 4242) }
    #expect(await harness.next() == .appQuit(pid: 4242))
    held.open()
    #expect(await registering.bounded() == .some(nil))
    await quitting.bounded()
    await harness.expectEvents([])
}

// MARK: Announcing only under a claim that observes placement

private let foundWindow = WindowHandle(pid: 4242, windowID: 5001, isStable: true)

@Test(.timeLimit(.minutes(1)))
func aCreationDeliveredUnderAnEndedClaimAnnouncesNothingAndLeavesTheWindowToTheNextClaim() async {
    let harness = ObservationHarness(isLaunching: false, outcomes: [[:]])
    _ = await harness.observation.observe(launching, as: .restart)
    harness.observation.end()
    harness.observation.begin()
    _ = await harness.observation.observe(launching, as: .restart)
    // A callback the first registration queued arrives after the restart.
    harness.handlers.deliver(notification(kAXWindowCreatedNotification, 5001), through: 0)
    harness.handlers.deliver(notification(kAXWindowMovedNotification, 5001), through: 1)
    #expect(await harness.next() == outcome([]))
    #expect(await harness.next() == outcome([]))
    #expect(await harness.next() == .windowMoved(foundWindow))
    // It marked nothing: the current registration's own creation announces the window.
    harness.handlers.deliver(notification(kAXWindowCreatedNotification, 5001), through: 1)
    guard case .windowCreated(let snapshot)? = await harness.next() else {
        Issue.record("expected the current claim to announce the window")
        return
    }
    #expect(snapshot.handle == foundWindow)
    #expect(harness.notices.all == [.announced(foundWindow)])
}

@Test(.timeLimit(.minutes(1)))
func aCreationIsNotAnnouncedWhileTheRegistrationMissesMoves() async {
    let harness = ObservationHarness(isLaunching: false, outcomes: [[kAXWindowMovedNotification: .failure], [:]])
    _ = await harness.observation.observe(launching, as: .restart)
    harness.handlers.deliver(notification(kAXWindowCreatedNotification, 5001), through: 0)
    harness.handlers.deliver(notification(kAXWindowResizedNotification, 5001), through: 0)
    #expect(await harness.next() == outcome([.moved]))
    #expect(await harness.next() == .windowResized(foundWindow))
    #expect(harness.notices.all.isEmpty)
    // Once a registration observes placement, the app's creations are announced.
    #expect(await harness.observation.observeAgain(launching) == nil)
    harness.handlers.deliver(notification(kAXWindowCreatedNotification, 5001), through: 1)
    #expect(await harness.next() == outcome([]))
    guard case .windowCreated(let snapshot)? = await harness.next() else {
        Issue.record("expected the creation to be announced")
        return
    }
    #expect(snapshot.handle == foundWindow)
    #expect(harness.notices.all == [.announced(foundWindow)])
}

// MARK: Catch-up

@Test(.timeLimit(.minutes(1)))
func aLaunchMissingOnlyTitleChangesStillAnnouncesItsWindows() async {
    let harness = ObservationHarness(
        isLaunching: false, outcomes: [[kAXTitleChangedNotification: .notificationUnsupported]], found: [5001])
    await harness.observation.appLaunched(launching)
    await harness.expectEvents([
        .appLaunched(pid: 4242, bundleID: "com.example.Slow"), outcome([.titleChanged]),
        .windowCreated(Windows27.snapshot(handle: foundWindow, app: launching, attributes: catchUpAttributes)),
    ])
    #expect(harness.notices.all == [.announced(foundWindow)])
}

@Test(.timeLimit(.minutes(1)))
func aCatchUpAnnouncesAWindowAQueryRegisteredFirst() async {
    let harness = ObservationHarness(isLaunching: false, outcomes: [[:]], found: [5001])
    _ = harness.registry.register(windowBox(5001), pid: 4242, windowID: ResolvedWindowID(id: 5001, by: .privateSymbol))
    await harness.observation.appLaunched(launching)
    await harness.expectEvents([
        .appLaunched(pid: 4242, bundleID: "com.example.Slow"), outcome([]),
        .windowCreated(Windows27.snapshot(handle: foundWindow, app: launching, attributes: catchUpAttributes)),
    ])
}

/// A window's end is its destruction or its app's quit, never a failed read: the quit takes every
/// registration of the app and tells the notices and the core.
@Test(.timeLimit(.minutes(1)))
func anAppsQuitEndsItsRegisteredWindows() async {
    let harness = ObservationHarness(isLaunching: false, outcomes: [[:]])
    let window = harness.registry.handle(
        for: windowBox(5001), pid: 4242, windowID: ResolvedWindowID(id: 5001, by: .privateSymbol))
    await harness.observation.appQuit(pid: 4242)
    #expect(await harness.next() == .appQuit(pid: 4242))
    #expect(harness.registry.element(for: window) == nil)
    #expect(harness.notices.all == [.quit(4242)])
}

@Test(.gated, .timeLimit(.minutes(1)))
func aCatchUpForAnAppThatQuitMeanwhilePublishesAndKeepsNothing() async {
    let gate = Gate()
    let harness = ObservationHarness(isLaunching: false, outcomes: [[:]], found: [5001], catchUpGate: gate)
    let observation = harness.observation
    let launch = Task { await observation.appLaunched(launching) }
    await gate.waitUntilHolding(1)
    harness.isRunning.isSet = false
    await observation.appQuit(pid: 4242)
    gate.release()
    await launch.bounded()
    await harness.expectEvents([.appLaunched(pid: 4242, bundleID: "com.example.Slow"), outcome([]), .appQuit(pid: 4242)])
    #expect(harness.registry.knownHandle(of: windowBox(5001)) == nil)
    // Nothing found under the ended claim was announced; the quit reached the notices.
    #expect(harness.notices.all == [.quit(4242)])
}

@Test(.gated, .timeLimit(.minutes(1)))
func aCatchUpOvertakenByARestartLeavesItsWindowsToTheNewRun() async {
    let gate = Gate()
    let harness = ObservationHarness(isLaunching: false, outcomes: [[:]], found: [5001], catchUpGate: gate)
    let observation = harness.observation
    let launch = Task { await observation.appLaunched(launching) }
    await gate.waitUntilHolding(1)
    observation.end()
    observation.begin()
    gate.release()
    await launch.bounded()
    // The stale catch-up published nothing and withdrew nothing: the app still runs.
    #expect(harness.registry.knownHandle(of: windowBox(5001)) == foundWindow)
    // The new run observes the app, adopts the window and owes it its announcement still.
    let observing = Task { await observation.observe(launching, as: .restart) }
    await gate.waitUntilHolding(1)
    gate.release()
    _ = await observing.bounded()
    await harness.expectEvents([
        .appLaunched(pid: 4242, bundleID: "com.example.Slow"), outcome([]), outcome([]),
        .windowCreated(Windows27.snapshot(handle: foundWindow, app: launching, attributes: catchUpAttributes)),
    ])
}

@Test(.timeLimit(.minutes(1)))
func aLaunchAQueryMetFirstStillAnnouncesItsWindows() async {
    let harness = ObservationHarness(isLaunching: false, outcomes: [[:]], found: [5001])
    // A query claims and registers the app before its launch is handled.
    await harness.observation.discover(launching)
    await harness.observation.appLaunched(launching)
    await harness.expectEvents([
        outcome([]), .appLaunched(pid: 4242, bundleID: "com.example.Slow"),
        .windowCreated(Windows27.snapshot(handle: foundWindow, app: launching, attributes: catchUpAttributes)),
    ])
    #expect(harness.registrations.count == 1)
}

@Test(.timeLimit(.minutes(1)))
func anAppWhoseLaunchRegistrationFailedAnnouncesItsWindowsOnceWhenItIsRegisteredAgain() async {
    let failed: [String: AXError] = [kAXWindowCreatedNotification: .notificationUnsupported]
    let harness = ObservationHarness(isLaunching: false, outcomes: [failed, [:]], found: [5001])
    await harness.observation.appLaunched(launching)
    // The launch registered without creations: it announced nothing, and the debt stands.
    #expect(harness.announcements.count == 0)
    #expect(await harness.observation.observeAgain(launching) == nil)
    #expect(harness.announcements.count == 1)
    // The debt is paid: a further registration announces nothing.
    #expect(await harness.observation.observeAgain(launching) == nil)
    #expect(harness.announcements.count == 1)
    // Each registration's outcome comes before the windows it announces.
    await harness.expectEvents([
        .appLaunched(pid: 4242, bundleID: "com.example.Slow"), outcome([.created]), outcome([]),
        .windowCreated(Windows27.snapshot(handle: foundWindow, app: launching, attributes: catchUpAttributes)),
        outcome([]),
    ])
    #expect(harness.notices.all == [.announced(foundWindow)])
}

@Test(.timeLimit(.minutes(1)))
func aWindowTheCatchUpAnnouncedFirstIsNotAnnouncedAgainByItsCreation() async {
    let harness = ObservationHarness(isLaunching: false, outcomes: [[:]], found: [5001])
    await harness.observation.appLaunched(launching)
    harness.handlers.deliver(notification(kAXWindowCreatedNotification, 5001), through: 0)
    harness.handlers.deliver(notification(kAXWindowMovedNotification, 5001), through: 0)
    #expect(await harness.next() == .appLaunched(pid: 4242, bundleID: "com.example.Slow"))
    #expect(await harness.next() == outcome([]))
    guard case .windowCreated? = await harness.next() else {
        Issue.record("expected the catch-up to announce the window")
        return
    }
    #expect(await harness.next() == .windowMoved(foundWindow))
}

@Test(.timeLimit(.minutes(1)))
func aWindowItsCreationAnnouncedFirstIsNotAnnouncedAgainByTheCatchUp() async {
    let harness = ObservationHarness(isLaunching: false, outcomes: [[:]], found: [5001])
    await harness.observation.discover(launching)
    harness.handlers.deliver(notification(kAXWindowCreatedNotification, 5001), through: 0)
    #expect(await harness.next() == outcome([]))
    guard case .windowCreated? = await harness.next() else {
        Issue.record("expected the creation to be announced")
        return
    }
    await harness.observation.appLaunched(launching)
    await harness.expectEvents([.appLaunched(pid: 4242, bundleID: "com.example.Slow")])
    #expect(harness.notices.all == [.announced(foundWindow)])
}

// MARK: Announcing is one step

@Test(.gated, .timeLimit(.minutes(1)))
func aCatchUpOvertakenByARestartAfterItsEnumerationLeavesExactlyOneAnnouncement() async {
    let gate = Gate()
    let harness = ObservationHarness(isLaunching: false, outcomes: [[:]], found: [5001], catchUpGate: gate)
    let observation = harness.observation
    // The launch's catch-up has enumerated; its claim is checked only in the announcing step.
    let launch = Task { await observation.appLaunched(launching) }
    await gate.waitUntilHolding(1)
    observation.end()
    observation.begin()
    let observing = Task { await observation.observe(launching, as: .restart) }
    await gate.waitUntilHolding(2)
    // The stale catch-up and the new run's go on together; only the new claim's step announces.
    gate.release()
    await launch.bounded()
    _ = await observing.bounded()
    await harness.expectEvents([
        .appLaunched(pid: 4242, bundleID: "com.example.Slow"), outcome([]), outcome([]),
        .windowCreated(Windows27.snapshot(handle: foundWindow, app: launching, attributes: catchUpAttributes)),
    ])
    // The mark stays: the window's own creation notification announces nothing more.
    harness.handlers.deliver(notification(kAXWindowCreatedNotification, 5001), through: 1)
    harness.handlers.deliver(notification(kAXWindowMovedNotification, 5001), through: 1)
    #expect(await harness.next() == .windowMoved(foundWindow))
}

@Test(.gated, .timeLimit(.minutes(1)))
func twoCatchUpsRacingOnOneWindowAnnounceItOnce() async {
    let gate = Gate()
    let harness = ObservationHarness(isLaunching: false, outcomes: [[:]], found: [5001], catchUpGate: gate)
    let observation = harness.observation
    // A query observes the app; two launch notifications then each owe and start a catch-up under its claim.
    await observation.discover(launching)
    let first = Task { await observation.appLaunched(launching) }
    let second = Task { await observation.appLaunched(launching) }
    await gate.waitUntilHolding(2)
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
