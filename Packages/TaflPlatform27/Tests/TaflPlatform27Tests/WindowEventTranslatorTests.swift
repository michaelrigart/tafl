import ApplicationServices
import CoreGraphics
import Testing
import TaflCore
@testable import TaflPlatform27

private let app = AppInfo27(pid: 10, bundleID: "com.example.App", name: "Example", isHidden: false)

private func box(_ pid: pid_t) -> AXElementBox { AXElementBox(AXUIElementCreateApplication(pid)) }

private func event(_ notification: String, pid: pid_t, element: AXElementBox) -> AXObserverHub.Event {
    AXObserverHub.Event(pid: pid, bundleID: nil, notification: notification, element: element.element)
}

private func attributes(subrole: String = "AXStandardWindow") -> WindowAttributes27 {
    WindowAttributes27(
        role: "AXWindow", subrole: subrole, title: "Doc", frame: CGRect(x: 0, y: 0, width: 100, height: 100),
        canMove: true, canResize: true, minSize: nil, isFullscreen: false, isMinimized: false)
}

/// A reader for elements named by the pid they were made from; `untracked` and `gone` shape what it answers,
/// and `gate` holds back every read for one app until the test opens it. Work for an app's queue runs at once.
private func reader(
    untracked: Set<pid_t> = [], gone: Set<pid_t> = [], gatedApp: pid_t? = nil, gate: AsyncStream<Void>? = nil
) -> WindowReader27 {
    WindowReader27(
        readTracked: { element, pid, _, then in
            if pid == gatedApp, let gate { for await _ in gate { break } }
            let elementPID = AXWindowAccess.pid(element.element) ?? 0
            guard !untracked.contains(elementPID) else { return nil }
            return then(ElementRead(element: element, attributes: attributes(), windowID: ResolvedWindowID(id: UInt32(elementPID), by: .privateSymbol)))
        },
        title: { _, _ in "Fresh" },
        app: { pid in gone.contains(pid) ? nil : AppInfo27(pid: pid, bundleID: nil, name: "App", isHidden: false) },
        afterReads: { _, work in work() })
}

private func handle(_ pid: pid_t, _ windowID: pid_t) -> WindowHandle {
    WindowHandle(pid: pid, windowID: UInt32(windowID), isStable: true)
}

private struct Harness {
    let translator: WindowEventTranslator
    let registry = WindowRegistry()
    let notices = RecordedNotices()
    var iterator: AsyncStream<PlatformEvent>.Iterator

    init(_ reader: WindowReader27) {
        let (stream, continuation) = AsyncStream<PlatformEvent>.makeStream()
        translator = WindowEventTranslator(registry: registry, reader: reader, events: continuation, notices: notices)
        iterator = stream.makeAsyncIterator()
    }

    mutating func next() async -> PlatformEvent? { await iterator.next() }
}

// Events of one app arrive in order, so an event the translator drops shows as the next one arriving first.

@Test(.timeLimit(.minutes(1)))
func aDestroyForAnUnknownWindowIsDropped() async {
    var harness = Harness(reader())
    harness.translator.enqueue(event(kAXUIElementDestroyedNotification, pid: 10, element: box(1010)))
    harness.translator.enqueue(event(kAXWindowMovedNotification, pid: 10, element: box(2020)))
    #expect(await harness.next() == .windowMoved(handle(10, 2020)))
    harness.translator.closeAll()
}

@Test(.timeLimit(.minutes(1)))
func eventsForWindowsThatAreNotStandardOrSheetsAreDropped() async {
    var harness = Harness(reader(untracked: [1010]))
    for notification in [kAXWindowCreatedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification, kAXTitleChangedNotification] {
        harness.translator.enqueue(event(notification, pid: 10, element: box(1010)))
    }
    harness.translator.enqueue(event(kAXWindowMovedNotification, pid: 10, element: box(2020)))
    #expect(await harness.next() == .windowMoved(handle(10, 2020)))
    #expect(harness.registry.knownHandle(of: box(1010)) == nil)
    harness.translator.closeAll()
}

@Test(.timeLimit(.minutes(1)))
func aWindowOfAProcessThatIsGoneIsNotRegistered() async {
    var harness = Harness(reader(gone: [10]))
    _ = harness.registry.register(box(2020), pid: 10, windowID: ResolvedWindowID(id: 2020, by: .privateSymbol))
    harness.translator.enqueue(event(kAXWindowCreatedNotification, pid: 10, element: box(1010)))
    harness.translator.enqueue(event(kAXWindowMovedNotification, pid: 10, element: box(2020)))
    #expect(await harness.next() == .windowMoved(handle(10, 2020)))
    #expect(harness.registry.knownHandle(of: box(1010)) == nil)
    harness.translator.closeAll()
}

@Test(.timeLimit(.minutes(1)))
func aCreatedWindowIsAnnouncedOnceAndItsTitleIsReadFresh() async {
    var harness = Harness(reader())
    harness.translator.enqueue(event(kAXWindowCreatedNotification, pid: 10, element: box(1010)))
    harness.translator.enqueue(event(kAXWindowCreatedNotification, pid: 10, element: box(1010)))
    harness.translator.enqueue(event(kAXTitleChangedNotification, pid: 10, element: box(1010)))
    guard case .windowCreated(let snapshot)? = await harness.next() else {
        Issue.record("expected windowCreated")
        return
    }
    #expect(snapshot.handle == handle(10, 1010))
    #expect(snapshot.title == "Doc")
    #expect(await harness.next() == .titleChanged(handle(10, 1010), "Fresh"))
    // The read that found the window handed its announcement to the notices, once.
    #expect(harness.notices.all == [.announced(handle(10, 1010))])
    harness.translator.closeAll()
}

@Test(.timeLimit(.minutes(1)))
func aWindowTheCatchUpAlreadyAnnouncedIsNotAnnouncedByItsNotification() async {
    var harness = Harness(reader())
    let registered = harness.registry.register(box(1010), pid: 10, windowID: ResolvedWindowID(id: 1010, by: .privateSymbol))
    let found = WindowSnapshot(
        handle: registered.handle, bundleID: nil, appName: "App", title: "Doc", frame: ScreenRect(x: 0, y: 0, width: 100, height: 100),
        canMove: true, canResize: true, minSize: nil, isFullscreen: false, isSheet: false, isMinimized: false, isAppHidden: false)
    _ = harness.registry.announce(found) { _ in true }
    harness.translator.enqueue(event(kAXWindowCreatedNotification, pid: 10, element: box(1010)))
    harness.translator.enqueue(event(kAXWindowMovedNotification, pid: 10, element: box(1010)))
    #expect(await harness.next() == .windowMoved(handle(10, 1010)))
    #expect(harness.notices.all.isEmpty)
    harness.translator.closeAll()
}

@Test(.timeLimit(.minutes(1)))
func aWindowAQueryRegisteredIsAnnouncedOnceByItsCreation() async {
    var harness = Harness(reader())
    // A query met the window before its creation notification was handled.
    _ = harness.registry.register(box(1010), pid: 10, windowID: ResolvedWindowID(id: 1010, by: .privateSymbol))
    harness.translator.enqueue(event(kAXWindowCreatedNotification, pid: 10, element: box(1010)))
    harness.translator.enqueue(event(kAXWindowCreatedNotification, pid: 10, element: box(1010)))
    harness.translator.enqueue(event(kAXWindowMovedNotification, pid: 10, element: box(1010)))
    guard case .windowCreated(let snapshot)? = await harness.next() else {
        Issue.record("expected the creation to be announced")
        return
    }
    #expect(snapshot.handle == handle(10, 1010))
    #expect(await harness.next() == .windowMoved(handle(10, 1010)))
    harness.translator.closeAll()
}

@Test(.timeLimit(.minutes(1)))
func aKnownWindowIsMovedResizedAndDestroyedInOrderAndForgotten() async {
    var harness = Harness(reader())
    _ = harness.registry.register(box(1010), pid: 10, windowID: ResolvedWindowID(id: 1010, by: .privateSymbol))
    for notification in [kAXWindowMovedNotification, kAXWindowResizedNotification, kAXUIElementDestroyedNotification] {
        harness.translator.enqueue(event(notification, pid: 10, element: box(1010)))
    }
    #expect(await harness.next() == .windowMoved(handle(10, 1010)))
    #expect(await harness.next() == .windowResized(handle(10, 1010)))
    #expect(await harness.next() == .windowDestroyed(handle(10, 1010)))
    #expect(harness.registry.knownHandle(of: box(1010)) == nil)
    // Moves and resizes are no announcements; the end reaches the notices through the app's queue.
    #expect(harness.notices.all == [.destroyed(handle(10, 1010))])
    harness.translator.closeAll()
}

@Test(.timeLimit(.minutes(1)))
func aSlowAppDelaysOnlyItselfAndKeepsItsOwnOrder() async {
    let (gate, open) = AsyncStream<Void>.makeStream()
    var harness = Harness(reader(gatedApp: 10, gate: gate))
    harness.translator.enqueue(event(kAXWindowCreatedNotification, pid: 10, element: box(1010)))
    harness.translator.enqueue(event(kAXTitleChangedNotification, pid: 10, element: box(1010)))
    harness.translator.enqueue(event(kAXWindowMovedNotification, pid: 11, element: box(1011)))
    #expect(await harness.next() == .windowMoved(handle(11, 1011)))

    open.yield()
    guard case .windowCreated(let snapshot)? = await harness.next() else {
        Issue.record("the created window must come before its title change")
        return
    }
    #expect(snapshot.handle == handle(10, 1010))
    #expect(await harness.next() == .titleChanged(handle(10, 1010), "Fresh"))
    harness.translator.closeAll()
}

@Test(.timeLimit(.minutes(1)))
func aLateCallbackAfterTheLaneClosedStartsNoLaneUntilTheNextClaim() async {
    var harness = Harness(reader())
    harness.translator.enqueue(event(kAXWindowMovedNotification, pid: 10, element: box(1010)))
    #expect(await harness.next() == .windowMoved(handle(10, 1010)))
    harness.translator.closeLane(pid: 10)
    harness.translator.enqueue(event(kAXWindowMovedNotification, pid: 10, element: box(2020)))
    #expect(harness.translator.laneCount == 0)

    harness.translator.reopen(pid: 10)
    harness.translator.enqueue(event(kAXWindowMovedNotification, pid: 10, element: box(2020)))
    #expect(await harness.next() == .windowMoved(handle(10, 2020)))
    #expect(harness.translator.laneCount == 1)
    harness.translator.closeAll()
}
