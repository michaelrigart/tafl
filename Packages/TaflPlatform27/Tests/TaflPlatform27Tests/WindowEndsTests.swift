import ApplicationServices
import Testing
import TaflCore
@testable import TaflPlatform27

private let gone: Result<Int, AXFailure> = .failure(AXFailure(.invalidUIElement))

// Each test ends with a move of a second window, so an end delivered late, or twice, shows in the
// events before it.

/// A read that finds the element invalid, as around a wake, ends nothing: the window stays registered
/// and the owner is not told. Its destruction notification then ends it, once.
@Test(.timeLimit(.minutes(1)))
func aWindowAReadFindsInvalidIsEndedOnlyByItsDestruction() async {
    var harness = EndsHarness()
    let window = harness.register(1010)
    let marker = harness.register(2020)
    let result = await Platform27.readRegistered(window, registry: harness.registry) { _ in gone }
    #expect(result == gone)
    #expect(harness.registry.element(for: window) == harness.element(1010))
    #expect(harness.notices.all.isEmpty)
    harness.notify(kAXUIElementDestroyedNotification, 1010)
    harness.notify(kAXWindowMovedNotification, 2020)
    #expect(await harness.events(through: .windowMoved(marker)) == [.windowDestroyed(window), .windowMoved(marker)])
    #expect(harness.registry.element(for: window) == nil)
    #expect(harness.notices.all == [.destroyed(window)])
    harness.translator.closeAll()
}

/// The destruction notification is handled while a read of the window is in flight: the notification
/// ends the window once, and the read that then finds the element invalid adds nothing.
@Test(.timeLimit(.minutes(1)))
func aDestructionHandledDuringAReadEndsTheWindowOnce() async {
    var harness = EndsHarness()
    let window = harness.register(1010)
    let marker = harness.register(2020)
    let result = await Platform27.readRegistered(window, registry: harness.registry) { _ in
        harness.notify(kAXUIElementDestroyedNotification, 1010)
        await harness.notices.waitForNotices(1)
        return gone
    }
    #expect(result == gone)
    harness.notify(kAXWindowMovedNotification, 2020)
    #expect(await harness.events(through: .windowMoved(marker)) == [.windowDestroyed(window), .windowMoved(marker)])
    #expect(harness.notices.all == [.destroyed(window)])
    harness.translator.closeAll()
}

/// A replacement element is registered for the window's id after the destroyed element was looked up.
/// The end, with the pair the lookup found, removes nothing: the new registration stays, and nothing
/// is announced as destroyed.
@Test(.timeLimit(.minutes(1)))
func aReplacementRegisteredBeforeAnEndStaysAndIsNotEnded() async {
    var harness = EndsHarness()
    let window = harness.register(1010)
    let marker = harness.register(2020)
    let looked = harness.registry.knownHandle(of: harness.element(1010))
    #expect(looked == window)
    let replacement = harness.register(3030, as: 1010)
    #expect(replacement == window)
    harness.ends.end(window, harness.element(1010))
    #expect(harness.registry.element(for: window) == harness.element(3030))
    harness.notify(kAXWindowMovedNotification, 2020)
    #expect(await harness.events(through: .windowMoved(marker)) == [.windowMoved(marker)])
    #expect(harness.notices.all.isEmpty)
    harness.translator.closeAll()
}

/// A read of the app queued ahead of a dead window's end registers a new element for the window's id
/// and hands its reading over. The end's withdraw and its notice run together after that read, on the
/// app's queue: the withdraw finds the new registration, removes nothing, and nothing announces the
/// window as destroyed, so the state that reading gave the owner stays.
@Test(.timeLimit(.minutes(1)))
func aRegistrationForTheIDQueuedAheadOfAnEndKeepsItsState() async {
    let queue = ManualQueue()
    var harness = EndsHarness(queue: queue)
    let window = harness.register(1010)
    let marker = harness.register(2020)
    let registry = harness.registry
    let notices = harness.notices
    queue.enqueue {
        let handle = registry.handle(
            for: AXElementBox(AXUIElementCreateApplication(3030)), pid: EndsHarness.pid,
            windowID: ResolvedWindowID(id: 1010, by: .privateSymbol))
        notices.announced(WindowSnapshot(
            handle: handle, bundleID: nil, appName: "App", title: "Doc",
            frame: ScreenRect(x: 0, y: 0, width: 100, height: 100), canMove: true, canResize: true, minSize: nil,
            isFullscreen: false, isSheet: false, isMinimized: false, isAppHidden: false))
    }
    harness.notify(kAXUIElementDestroyedNotification, 1010)
    await queue.waitForQueued(2)
    queue.drain()
    #expect(harness.registry.element(for: window) == harness.element(3030))
    harness.notify(kAXWindowMovedNotification, 2020)
    #expect(await harness.events(through: .windowMoved(marker)) == [.windowMoved(marker)])
    #expect(harness.notices.all == [.announced(window)])
    harness.translator.closeAll()
}
