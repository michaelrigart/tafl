import ApplicationServices
import Synchronization
import Testing
import TaflCore
@testable import TaflPlatform27

private func box(_ pid: pid_t) -> AXElementBox { AXElementBox(AXUIElementCreateApplication(pid)) }
private func exact(_ id: UInt32) -> ResolvedWindowID { ResolvedWindowID(id: id, by: .privateSymbol) }
private func guess(_ id: UInt32) -> ResolvedWindowID { ResolvedWindowID(id: id, by: .windowList) }

@Test func theSameElementKeepsItsHandle() async {
    let registry = WindowRegistry()
    let first = await registry.handle(for: box(10), pid: 10, windowID: exact(7))
    let again = await registry.handle(for: box(10), pid: 10, windowID: exact(7))
    #expect(first == WindowHandle(pid: 10, windowID: 7, isStable: true))
    #expect(again == first)
}

@Test func anElementKeepsItsHandleEvenWhenResolutionLaterDiffers() async {
    let registry = WindowRegistry()
    let first = await registry.handle(for: box(10), pid: 10, windowID: nil)
    let again = await registry.handle(for: box(10), pid: 10, windowID: exact(99))
    #expect(again == first)
}

@Test func anUnresolvedWindowGetsAnUnstableHandleThatStaysTheSame() async {
    let registry = WindowRegistry()
    let first = await registry.handle(for: box(10), pid: 10, windowID: nil)
    let other = await registry.handle(for: box(11), pid: 11, windowID: nil)
    let again = await registry.handle(for: box(10), pid: 10, windowID: nil)
    #expect(!first.isStable)
    #expect(first.pid == 10)
    #expect(again == first)
    #expect(other != first)
}

@Test func syntheticHandlesAreNeverEqualToResolvedOnes() async {
    let registry = WindowRegistry()
    let synthetic = await registry.handle(for: box(10), pid: 10, windowID: nil)
    let resolved = await registry.handle(for: box(11), pid: 10, windowID: exact(synthetic.windowID))
    #expect(resolved != synthetic)
    #expect(resolved.isStable)
}

@Test func registrationReportsWhetherItInserted() async {
    let registry = WindowRegistry()
    let first = await registry.register(box(10), pid: 10, windowID: exact(7))
    let again = await registry.register(box(10), pid: 10, windowID: exact(7))
    #expect(first.isNew)
    #expect(!again.isNew)
    #expect(again.handle == first.handle)
}

@Test func aHandleLeadsBackToItsElementAndAnElementToItsHandle() async {
    let registry = WindowRegistry()
    let handle = await registry.handle(for: box(10), pid: 10, windowID: exact(7))
    #expect(await registry.element(for: handle) == box(10))
    #expect(await registry.knownHandle(of: box(10)) == handle)
    #expect(await registry.knownHandle(of: box(11)) == nil)
}

@Test func aRecreatedElementWithAnExactIDReplacesTheOldOne() async {
    let registry = WindowRegistry()
    let old = box(10)
    let handle = await registry.handle(for: old, pid: 10, windowID: exact(7))
    let renewed = AXElementBox(AXUIElementCreateSystemWide())
    let again = await registry.handle(for: renewed, pid: 10, windowID: exact(7))
    #expect(again == handle)
    #expect(await registry.element(for: handle) == renewed)
    #expect(await registry.knownHandle(of: old) == nil)
}

@Test func aWindowListGuessNeverEvictsTheElementHoldingTheID() async {
    let registry = WindowRegistry()
    let holder = box(10)
    let held = await registry.handle(for: holder, pid: 10, windowID: guess(7))
    let newcomer = AXElementBox(AXUIElementCreateSystemWide())
    let other = await registry.handle(for: newcomer, pid: 10, windowID: guess(7))
    #expect(held == WindowHandle(pid: 10, windowID: 7, isStable: true))
    #expect(!other.isStable)
    #expect(await registry.element(for: held) == holder)
    #expect(await registry.element(for: other) == newcomer)
}

@Test func theElementsOfOneAppAreListed() async {
    let registry = WindowRegistry()
    _ = await registry.handle(for: box(10), pid: 10, windowID: exact(7))
    _ = await registry.handle(for: box(11), pid: 11, windowID: exact(8))
    #expect(await registry.elements(pid: 10) == [box(10)])
    #expect(await registry.elements(pid: 12).isEmpty)
}

@Test func destroyedWindowsAndQuitAppsAreDropped() async {
    let registry = WindowRegistry()
    let gone = await registry.handle(for: box(10), pid: 10, windowID: exact(7))
    let kept = await registry.handle(for: box(11), pid: 11, windowID: exact(8))
    await registry.remove(gone)
    #expect(await registry.element(for: gone) == nil)
    #expect(await registry.element(for: kept) != nil)

    _ = await registry.handle(for: AXElementBox(AXUIElementCreateSystemWide()), pid: 11, windowID: exact(9))
    await registry.removeApp(pid: 11)
    #expect(await registry.element(for: kept) == nil)
    #expect(await registry.count == 0)
}

private let readAt = ContinuousClock.now

private func snapshot(_ handle: WindowHandle) -> WindowSnapshot {
    WindowSnapshot(
        handle: handle, bundleID: nil, appName: "App", title: "Doc", frame: ScreenRect(x: 0, y: 0, width: 100, height: 100),
        canMove: true, canResize: true, minSize: nil, isFullscreen: false, isSheet: false, isMinimized: false, isAppHidden: false,
        readAt: readAt)
}

/// Collects what an announcing step publishes, accepting or refusing as told.
private final class Publisher: Sendable {
    private let published = Mutex<[PlatformEvent]>([])
    let accepts: Bool

    init(accepts: Bool = true) { self.accepts = accepts }

    var events: [PlatformEvent] { published.withLock { $0 } }

    func publish(_ event: PlatformEvent) -> Bool {
        guard accepts else { return false }
        published.withLock { $0.append(event) }
        return true
    }
}

@Test func aWindowIsAnnouncedInOneStepAndOnlyOnce() async {
    let registry = WindowRegistry()
    let handle = await registry.handle(for: box(10), pid: 10, windowID: exact(7))
    let publisher = Publisher()
    #expect(await registry.announce(snapshot(handle), publish: publisher.publish) == .announced)
    #expect(await registry.announce(snapshot(handle), publish: publisher.publish) == .alreadyAnnounced)
    let other = WindowHandle(pid: 10, windowID: 8, isStable: true)
    #expect(await registry.announce(snapshot(other), publish: publisher.publish) == .unregistered)
    #expect(publisher.events == [.windowCreated(snapshot(handle))])
}

@Test func aRefusedStepLeavesTheWindowToBeAnnouncedLater() async {
    let registry = WindowRegistry()
    let handle = await registry.handle(for: box(10), pid: 10, windowID: exact(7))
    #expect(await registry.announce(snapshot(handle), publish: Publisher(accepts: false).publish) == .refused)
    let publisher = Publisher()
    #expect(await registry.announce(snapshot(handle), publish: publisher.publish) == .announced)
    #expect(publisher.events == [.windowCreated(snapshot(handle))])
}

@Test func stepsRacingOnOneWindowAnnounceItOnce() async {
    let registry = WindowRegistry()
    let handle = await registry.handle(for: box(10), pid: 10, windowID: exact(7))
    let publisher = Publisher()
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<8 { group.addTask { _ = await registry.announce(snapshot(handle), publish: publisher.publish) } }
    }
    #expect(publisher.events == [.windowCreated(snapshot(handle))])
}

@Test func onlyTheSameRegistrationIsWithdrawn() async {
    let registry = WindowRegistry()
    let mine = await registry.handle(for: box(10), pid: 10, windowID: exact(7))
    // Another element took the handle since: it is not the registration the owner made.
    let replaced = await registry.handle(for: box(11), pid: 10, windowID: exact(8))
    _ = await registry.handle(for: box(12), pid: 10, windowID: exact(8))
    await registry.withdraw([(mine, box(10)), (replaced, box(11))])
    #expect(await registry.knownHandle(of: box(10)) == nil)
    #expect(await registry.knownHandle(of: box(12)) == replaced)
}
