import ApplicationServices
import Testing
import TaflCore
@testable import TaflPlatform27

private let gone: Result<Int, AXFailure> = .failure(AXFailure(.invalidUIElement))

// Each test ends with a move of a second window, so an end delivered late, or twice, shows in the
// events before it.

/// A snapshot that finds the element invalid ends the window: the owner hears of it and the engine
/// gets the event. The destruction notification that follows finds it ended and delivers nothing.
@Test(.timeLimit(.minutes(1)))
func aWindowASnapshotFindsGoneEndsOnceThoughItsDestructionFollows() async {
    var harness = EndsHarness()
    let window = harness.register(1010)
    let marker = harness.register(2020)
    let result = await Platform27.readRegistered(window, ends: harness.ends) { _ in gone }
    #expect(result == gone)
    #expect(harness.registry.element(for: window) == nil)
    harness.notify(kAXUIElementDestroyedNotification, 1010)
    harness.notify(kAXWindowMovedNotification, 2020)
    #expect(await harness.events(through: .windowMoved(marker)) == [.windowDestroyed(window), .windowMoved(marker)])
    #expect(harness.notices.all == [.destroyed(window)])
    harness.translator.closeAll()
}

/// The destruction notification is handled while a snapshot reads the window: the notification ends
/// it, and the snapshot that then finds the element invalid ends nothing more.
@Test(.timeLimit(.minutes(1)))
func aWindowItsDestructionEndedIsNotEndedAgainByASnapshotThatFindsItGoneLate() async {
    var harness = EndsHarness()
    let window = harness.register(1010)
    let marker = harness.register(2020)
    let result = await Platform27.readRegistered(window, ends: harness.ends) { _ in
        harness.notify(kAXUIElementDestroyedNotification, 1010)
        #expect(await harness.waitForNotices(1))
        return gone
    }
    #expect(result == gone)
    harness.notify(kAXWindowMovedNotification, 2020)
    #expect(await harness.events(through: .windowMoved(marker)) == [.windowDestroyed(window), .windowMoved(marker)])
    #expect(harness.notices.all == [.destroyed(window)])
    harness.translator.closeAll()
}

/// The translator has looked the destroyed element up when a read registers a new element for the
/// window's id. The translator's withdraw, with the pair its lookup found, removes nothing: the new
/// registration stays, and nothing is announced as destroyed.
@Test(.timeLimit(.minutes(1)))
func aReplacementRegisteredBetweenTheTranslatorsLookupAndItsWithdrawStaysAndIsNotEnded() async {
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
