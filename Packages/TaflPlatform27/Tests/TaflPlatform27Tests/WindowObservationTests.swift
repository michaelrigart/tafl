import ApplicationServices
import Synchronization
import Testing
import TaflCore
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

private struct ObservationHarness {
    let observation: WindowObservation27
    let continuation: AsyncStream<PlatformEvent>.Continuation
    var iterator: AsyncStream<PlatformEvent>.Iterator
    let registrations: Counter
    let isRunning = Flag(true)
    let announcements = Counter()

    /// `outcomes` answers each registration in turn and then repeats its last answer.
    init(isLaunching: Bool = true, gate: AsyncStream<Void>? = nil, outcomes: [[String: AXError]]) {
        let (stream, continuation) = AsyncStream<PlatformEvent>.makeStream()
        let registrations = Counter()
        let isRunning = isRunning
        let announcements = announcements
        let axQueue = AXQueue()
        let registry = WindowRegistry()
        observation = WindowObservation27(
            axQueue: axQueue, registry: registry, catalog: WindowCatalog27(registry: registry, axQueue: axQueue),
            events: continuation,
            environment: .init(
                isRunning: { _ in isRunning.isSet },
                isLaunching: { _ in isLaunching },
                untilFinishedLaunching: { _ in if let gate { for await _ in gate { break } } },
                register: { _, _, _, _ in
                    let index = registrations.increment()
                    return outcomes[min(index, outcomes.count - 1)]
                },
                newWindows: { _ in
                    _ = announcements.increment()
                    return []
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
    await retry.value
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
    await retry.value
    await second.value
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
    await retry.value
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
    await retry.value
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
    await retry.value
    harness.continuation.yield(.reconfigurationEnded)
    #expect(await harness.next() == .reconfigurationEnded)
    #expect(harness.registrations.count == 1)
    #expect(harness.announcements.count == 0)
}

@Test(.timeLimit(.minutes(1)))
func aQueryThatMetAnAppBeforeItQuitRegistersAndReportsNothing() async {
    var harness = ObservationHarness(outcomes: [timeout])
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
        environment: .init(
            isRunning: { _ in flag.isSet },
            isLaunching: { _ in false },
            untilFinishedLaunching: { _ in },
            register: { _, _, _, _ in
                flag.isSet = false
                return timeout
            },
            newWindows: { _ in [] }))
    observation.begin()
    guard case .observed = await observation.attempt(launching) else {
        Issue.record("a quit app must not be reported")
        return
    }
}
