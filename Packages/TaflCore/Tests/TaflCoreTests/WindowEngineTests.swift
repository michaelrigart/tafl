import Foundation
import Synchronization
import Testing
@testable import TaflCore

private let handle = WindowHandle(pid: 100, windowID: 1, isStable: true)
private let bothDisplays = [displayA, displayB]

private let leftHalfA = rect(0, 25, 500, 775)
private let rightHalfA = rect(500, 25, 500, 775)
private let leftHalfB = rect(1000, 0, 1000, 1550)
private let start = rect(100, 100, 400, 300)

private let quiet = Duration.milliseconds(1500)
private let testTiming = EngineTiming(quietPeriod: quiet, reapplyDelay: nil)

private func config(
    gap: Double = 0,
    layouts: [LayoutDefinition] = []
) -> Config {
    Config(
        shortcuts: [:], repeatMode: .displays, gap: gap, step: 30,
        menuBarIcon: true, launchAtLogin: true, layouts: layouts
    )
}

private func layout(
    _ name: String,
    displays: [String] = [],
    _ entries: [LayoutEntry]
) -> LayoutDefinition {
    LayoutDefinition(name: name, displays: displays, shortcut: nil, entries: entries)
}

private func slot(
    _ place: NamedPlacement,
    app: String = "com.example.app",
    title: String? = nil,
    display: String? = nil
) -> LayoutEntry {
    LayoutEntry(app: app, title: title, place: place, display: display)
}

private func titled(_ window: WindowSnapshot, _ title: String) -> WindowSnapshot {
    var copy = window
    copy.title = title
    return copy
}

private func isClose(_ a: ScreenRect, _ b: ScreenRect) -> Bool {
    a.isClose(to: b, within: 1)
}

private final class ReportLog: Sendable {
    private let entries = Mutex<[EngineReport]>([])
    func add(_ report: EngineReport) { entries.withLock { $0.append(report) } }
    var all: [EngineReport] { entries.withLock { $0 } }
}

/// An engine over a `FakePlatform`, with the reports it sends collected as they arrive.
private final class Rig: Sendable {
    let clock = ManualClock()
    let fake: FakePlatform
    let engine: WindowEngine
    private let collected = ReportLog()
    private let collector: Task<Void, Never>

    init(
        displays: [Display] = [displayA],
        windows: [WindowSnapshot] = [],
        focused: WindowHandle? = handle,
        store: MemoryStore? = nil,
        timing: EngineTiming = testTiming,
        steps: [any AdjustStep] = [],
        configure: @escaping @Sendable (isolated FakePlatform) -> Void = { _ in }
    ) async {
        fake = FakePlatform(clock: clock, displays: displays)
        await fake.configure { fake in
            for window in windows { fake.windows[window.handle] = window }
            fake.focused = focused
            configure(fake)
        }
        let engine = WindowEngine(
            platform: fake, store: store, clock: clock, timing: timing,
            steps: steps, adjustments: MacOSAdjustment.measured27
        )
        self.engine = engine
        let sink = collected
        let reports = engine.reports
        collector = Task { for await report in reports { sink.add(report) } }
    }

    deinit { collector.cancel() }

    var reports: [EngineReport] { collected.all }

    func frame(of window: WindowHandle = handle) async -> ScreenRect? {
        await fake.windows[window]?.frame
    }

    var log: [String] { get async { await fake.callLog } }

    func emit(_ event: PlatformEvent) async { await fake.emit(event) }

    /// Whether the window's owner counts it as touched.
    func isTouched(_ window: WindowHandle = handle) async -> Bool {
        await engine.owner.isTouched(window)
    }

    /// Waits until the engine has dealt with `count` events in all.
    func waitForEvents(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
        let begun = ContinuousClock.now
        while await engine.eventsHandled < count {
            if begun.duration(to: .now) > .seconds(2) {
                Issue.record("Timed out waiting for \(count) events", sourceLocation: sourceLocation)
                return
            }
            await Task.yield()
        }
    }

    /// Waits until the window request queue has been asked for `count` requests in all.
    func waitForRequests(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
        let queue = await engine.queue
        let begun = ContinuousClock.now
        while await queue.requestCount < count {
            if begun.duration(to: .now) > .seconds(2) {
                Issue.record("Timed out waiting for \(count) requests", sourceLocation: sourceLocation)
                return
            }
            await Task.yield()
        }
    }

    /// Waits until `count` display changes have been handled in all.
    func waitForChanges(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
        let found = await pollUntil {
            reports.filter { if case .displayChangeHandled = $0 { true } else { false } }.count >= count
        }
        if !found { Issue.record("Timed out waiting for \(count) handled changes; got \(reports)", sourceLocation: sourceLocation) }
    }

    func waitForReport(
        sourceLocation: SourceLocation = #_sourceLocation,
        where matches: @Sendable (EngineReport) -> Bool
    ) async {
        let found = await pollUntil { reports.contains(where: matches) }
        if !found { Issue.record("Timed out waiting for a report; got \(reports)", sourceLocation: sourceLocation) }
    }

    func waitForFrame(
        _ expected: ScreenRect,
        of window: WindowHandle = handle,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        await fake.waitUntil(sourceLocation: sourceLocation) {
            $0.windows[window].map { isClose($0.frame, expected) } ?? false
        }
    }

    /// Waits until observation restarts have been asked for `count` times in all.
    func waitForRestarts(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
        let restarts = await engine.restarts
        let found = await pollUntil { restarts.current >= count }
        if !found { Issue.record("Timed out waiting for \(count) restarts", sourceLocation: sourceLocation) }
    }

    func waitUntilStopping(sourceLocation: SourceLocation = #_sourceLocation) async {
        let begun = ContinuousClock.now
        while await engine.isStopping == false {
            if begun.duration(to: .now) > .seconds(2) {
                Issue.record("Timed out waiting for stop to begin", sourceLocation: sourceLocation)
                return
            }
            await Task.yield()
        }
    }

    func waitUntilChangeIsSettled(sourceLocation: SourceLocation = #_sourceLocation) async {
        let begun = ContinuousClock.now
        while await engine.isFrozen {
            if begun.duration(to: .now) > .seconds(2) {
                Issue.record("Timed out waiting for the change to settle", sourceLocation: sourceLocation)
                return
            }
            await Task.yield()
        }
    }

    /// A display change as macOS sends it: began, ended, then the quiet period. `handled` is the
    /// number of events dealt with by the time both have been (including earlier ones).
    func changeDisplays(
        to displays: [Display],
        eventsHandledAfter handled: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        await fake.configure { $0.displays = displays }
        await emit(.reconfigurationBegan)
        await emit(.reconfigurationEnded)
        await waitForEvents(handled, sourceLocation: sourceLocation)
        await clock.waitForSleepers(1, sourceLocation: sourceLocation)
        await clock.advance(by: quiet)
    }
}

// MARK: Actions

@Test func shortcutPlacesFocusedWindow() async {
    let rig = await Rig(windows: [window(1, frame: start)])
    await rig.engine.start(config: config())
    await rig.engine.perform(.leftHalf)
    #expect(await rig.frame() == leftHalfA)
}

@Test func repeatReachesTheOtherDisplay() async {
    let rig = await Rig(displays: bothDisplays, windows: [window(1, frame: start)])
    await rig.engine.start(config: config())
    await rig.engine.perform(.rightHalf)
    #expect(await rig.frame() == rightHalfA)
    await rig.engine.perform(.rightHalf)
    #expect(await rig.frame() == leftHalfB)
}

@Test func externalMoveEndsTheRepeat() async {
    let rig = await Rig(displays: bothDisplays, windows: [window(1, frame: start)])
    await rig.engine.start(config: config())
    await rig.engine.perform(.rightHalf)
    await rig.fake.configure { $0.windows[handle]?.frame = rect(200, 200, 300, 300) }
    await rig.emit(.windowMoved(handle))
    await rig.waitForEvents(1)
    // Back where Tafl left it: only the event can tell that something moved it meanwhile.
    await rig.fake.configure { $0.windows[handle]?.frame = rightHalfA }
    await rig.engine.perform(.rightHalf)
    #expect(await rig.frame() == rightHalfA)
}

@Test func ownEventsDontBreakTheRepeat() async {
    let rig = await Rig(displays: bothDisplays, windows: [window(1, frame: start)])
    await rig.engine.start(config: config())
    await rig.engine.perform(.rightHalf)
    await rig.emit(.windowMoved(handle))
    await rig.emit(.windowResized(handle))
    await rig.waitForEvents(2)
    await rig.engine.perform(.rightHalf)
    #expect(await rig.frame() == leftHalfB)
}

@Test func restoreReturnsToTheStartOfTheChain() async {
    let rig = await Rig(windows: [window(1, frame: start)])
    await rig.engine.start(config: config())
    await rig.engine.perform(.leftHalf)
    await rig.engine.perform(.maximize)
    await rig.engine.perform(.restore)
    #expect(await rig.frame() == start)
}

@Test func revokedPermissionIsReported() async {
    let rig = await Rig(windows: [window(1, frame: start)]) { $0.accessibilityGranted = false }
    await rig.engine.start(config: config())
    await rig.engine.perform(.leftHalf)
    await rig.waitForReport { $0 == .failure(.permissionMissing, display: nil) }
    #expect(await rig.log.isEmpty)
    #expect(await rig.frame() == start)
}

@Test func noWindowIsReported() async {
    let rig = await Rig(windows: [], focused: nil)
    await rig.engine.start(config: config())
    await rig.engine.perform(.leftHalf)
    await rig.waitForReport { $0 == .failure(.noWindow, display: nil) }
}

@Test func aFailedActionNamesTheWindowsDisplay() async {
    var fixed = window(1, frame: rect(1100, 100, 400, 300))
    fixed.canMove = false
    let rig = await Rig(displays: bothDisplays, windows: [fixed])
    await rig.engine.start(config: config())
    await rig.engine.perform(.leftHalf)
    await rig.waitForReport { $0 == .failure(.cannotMove, display: displayB.identity) }
}

@Test func newerRequestSupersedesAnUnfinishedOne() async {
    let rig = await Rig(displays: bothDisplays, windows: [window(1, frame: start)])
    await rig.engine.start(config: config())
    // Call 0 is the session's begin; call 1 is the first write.
    let gate = await rig.fake.pause(beforeCall: 1)
    let first = Task { await rig.engine.perform(.rightHalf) }
    await rig.fake.waitUntil { _ in gate.waiterCount == 1 }
    let second = Task { await rig.engine.perform(.rightHalf) }
    // The queue has the second request once it has asked the first to stop.
    await rig.waitForRequests(2)
    gate.open()
    await first.value
    await second.value
    #expect(await rig.frame() == rightHalfA)
}

// MARK: Layouts

// The hung app has the lowest pid, so a run that went through the apps one by one would wait for it first.
@Test(.timeLimit(.minutes(1))) func hungAppDoesNotBlockOthers() async {
    let a = window(1, frame: start, pid: 100, bundleID: "com.a")
    let b = window(2, frame: start, pid: 200, bundleID: "com.b")
    let c = window(3, frame: start, pid: 50, bundleID: "com.c")
    let desk = layout("Work", [slot(.leftHalf, app: "com.a"), slot(.rightHalf, app: "com.b"), slot(.topHalf, app: "com.c")])
    let elsewhere = window(4, frame: start, pid: 400, bundleID: "com.d")
    let rig = await Rig(windows: [a, b, c, elsewhere], focused: elsewhere.handle) { $0.hung = [50] }
    await rig.engine.start(config: config(layouts: [desk]))

    let applying = Task { await rig.engine.applyLayout(named: "Work") }
    await rig.waitForFrame(leftHalfA, of: a.handle)
    await rig.waitForFrame(rightHalfA, of: b.handle)
    // The hung app's call is waiting on the clock; another app's shortcut still completes.
    await rig.clock.waitForSleepers(1)
    await rig.engine.perform(.maximize)
    #expect(await rig.frame(of: elsewhere.handle) == rect(0, 25, 1000, 775))
    #expect(rig.reports == [.memory(.fresh)])

    await rig.clock.advance(by: .milliseconds(500))
    await applying.value
    // The run is summed up, and its failure says why on the window's display.
    let failure = EngineReport.failure(.notResponding(app: "Example"), display: displayA.identity)
    await rig.waitForReport { $0 == failure }
    #expect(rig.reports == [.memory(.fresh), .layoutApplied(name: "Work", placed: 2, failed: 1), failure])
    #expect(await rig.engine.activeLayoutName == "Work")
}

@Test func aLayoutRunShowsOnlyItsFirstFailure() async {
    var a = window(1, frame: start, pid: 100, bundleID: "com.a")
    var b = window(2, frame: start, pid: 200, bundleID: "com.b")
    a.canMove = false
    b.canMove = false
    let desk = layout("Work", [slot(.leftHalf, app: "com.a"), slot(.rightHalf, app: "com.b")])
    let rig = await Rig(windows: [a, b], focused: nil)
    await rig.engine.start(config: config(layouts: [desk]))
    await rig.engine.applyLayout(named: "Work")
    await rig.waitForReport { $0 == .failure(.cannotMove, display: displayA.identity) }
    #expect(rig.reports == [
        .memory(.fresh),
        .layoutApplied(name: "Work", placed: 0, failed: 2),
        .failure(.cannotMove, display: displayA.identity),
    ])
}

@Test func aLayoutWithoutPermissionIsReportedAndMovesNothing() async {
    let desk = layout("Desk", [slot(.rightHalf)])
    let rig = await Rig(windows: [window(1, frame: start)]) { $0.accessibilityGranted = false }
    await rig.engine.start(config: config(layouts: [desk]))
    await rig.engine.applyLayout(named: "Desk")
    await rig.waitForReport { $0 == .failure(.permissionMissing, display: nil) }
    #expect(rig.reports == [.memory(.fresh), .failure(.permissionMissing, display: nil)])
    #expect(await rig.log.isEmpty)
    #expect(await rig.engine.activeLayoutName == nil)
}

@Test func applyingALayoutReachesAppsWeCannotObserve() async {
    let other = window(2, frame: start, pid: 200, bundleID: "com.b")
    let desk = layout("Work", [slot(.rightHalf, app: "com.b")])
    let rig = await Rig(windows: [other])
    await rig.engine.start(config: config(layouts: [desk]))
    await rig.emit(.unobservable(pid: 200, bundleID: "com.b", missing: [.moved]))
    await rig.waitForEvents(1)
    await rig.engine.applyLayout(named: "Work")
    #expect(await rig.frame(of: other.handle) == rightHalfA)
}

// MARK: New windows

@Test func newWindowPlacedWhileActive() async {
    let desk = layout("Desk", [slot(.rightHalf)])
    let rig = await Rig()
    await rig.engine.start(config: config(layouts: [desk]))
    await rig.engine.applyLayout(named: "Desk")
    let created = window(1, frame: start)
    await rig.fake.configure { $0.windows[created.handle] = created }
    await rig.emit(.windowCreated(created))
    await rig.waitForFrame(rightHalfA)
}

@Test func aLateCreationAnnouncementKeepsWhereTheUserPutTheWindow() async {
    let desk = layout("Desk", [slot(.rightHalf)])
    let rig = await Rig()
    await rig.engine.start(config: config(layouts: [desk]))
    await rig.engine.applyLayout(named: "Desk")
    let found = window(1, frame: start)
    await rig.fake.configure { $0.windows[found.handle] = found }
    // The user places the window before its creation is announced.
    await rig.engine.perform(.leftHalf)
    var announced = found
    announced.frame = leftHalfA
    await rig.emit(.windowCreated(announced))
    await rig.waitForEvents(1)
    #expect(await rig.frame() == leftHalfA)
    #expect(await rig.isTouched())
}

@Test func aLateAnnouncementLeavesAKnownWindowsMemoryAlone() async {
    let rig = await Rig()
    await rig.engine.start(config: config())
    let found = window(1, frame: start)
    await rig.fake.configure { $0.windows[found.handle] = found }
    // A catch-up reads the window at `start`; a shortcut then places it, and the announcement arrives.
    await rig.fake.announce(found)
    await rig.engine.perform(.leftHalf)
    await rig.fake.deliver(.windowCreated(found))
    await rig.waitForEvents(1)
    let known = await rig.engine.memory.read().lastKnown(handle, setup: DisplaySetup([displayA]))
    #expect(known?.relative == leftHalfA.relative(to: v))
}

@Test(.timeLimit(.minutes(1))) func anAnnouncementReadAfterAnEventsReadPlacesNothing() async {
    let desk = layout("Desk", [slot(.rightHalf)])
    let rig = await Rig(focused: nil)
    await rig.engine.start(config: config(layouts: [desk]))
    await rig.engine.applyLayout(named: "Desk")
    let found = window(1, frame: start)
    await rig.fake.configure { $0.windows[found.handle] = found }
    // A move event's read is the first Tafl has of the window; the announcement is read after it.
    await rig.emit(.windowMoved(handle))
    await rig.waitForEvents(1)
    await rig.emit(.windowCreated(found))
    await rig.waitForEvents(2)
    #expect(await rig.log.isEmpty)
    #expect(await !rig.isTouched())
    #expect(await rig.engine.memory.read().lastKnown(handle, setup: DisplaySetup([displayA]))?.relative == start.relative(to: v))
}

@Test(.timeLimit(.minutes(1))) func aWindowWhoseAnnouncementIsReadFirstIsPlacedThoughAMoveEventCameFirst() async {
    let desk = layout("Desk", [slot(.rightHalf)])
    let rig = await Rig(focused: nil)
    await rig.engine.start(config: config(layouts: [desk]))
    await rig.engine.applyLayout(named: "Desk")
    let found = window(1, frame: start)
    let reads = FakeGate()
    await rig.fake.configure { $0.windows[found.handle] = found; $0.snapshotGate = reads }
    // A move event came first, but its read waits; the announcement is read before it, at the same
    // frame. Read order decides: the window is new, and nothing moved it.
    await rig.emit(.windowMoved(handle))
    await rig.fake.waitUntil { _ in reads.waiterCount == 1 }
    await rig.emit(.windowCreated(found))
    reads.open()
    await rig.waitForFrame(rightHalfA)
    #expect(await !rig.isTouched())
}

@Test func aWindowTheSeedSawIsLeftAloneWhenItsCreationIsAnnounced() async {
    let (store, directory) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let desk = layout("Desk", [slot(.rightHalf)])
    let first = await Rig(store: store)
    await first.engine.start(config: config(layouts: [desk]))
    await first.engine.applyLayout(named: "Desk")
    await first.engine.stop()
    // The next launch's seed knows the window; its creation is announced later.
    let found = window(1, frame: start)
    let rig = await Rig(windows: [found], store: store)
    await rig.engine.start(config: config(layouts: [desk]))
    await rig.emit(.windowCreated(found))
    await rig.waitForEvents(1)
    #expect(await rig.log.isEmpty)
    #expect(await rig.frame() == start)
}

@Test func newWindowIsLeftAloneWithoutAnActiveLayout() async {
    let desk = layout("Desk", [slot(.rightHalf)])
    let rig = await Rig()
    await rig.engine.start(config: config(layouts: [desk]))
    let created = window(1, frame: start)
    await rig.fake.configure { $0.windows[created.handle] = created }
    await rig.emit(.windowCreated(created))
    await rig.waitForEvents(1)
    #expect(await rig.log.isEmpty)
}

@Test func titleCheckPlacesOnce() async {
    let desk = layout("Desk", [slot(.rightHalf, title: "*Docs*")])
    let rig = await Rig()
    await rig.engine.start(config: config(layouts: [desk]))
    await rig.engine.applyLayout(named: "Desk")
    let created = titled(window(1, frame: start), "Untitled")
    await rig.fake.configure { $0.windows[created.handle] = created }
    await rig.emit(.windowCreated(created))
    await rig.waitForEvents(1)
    #expect(await rig.log.isEmpty)

    await rig.fake.configure { $0.windows[handle]?.title = "Docs home" }
    await rig.emit(.titleChanged(handle, "Docs home"))
    await rig.waitForFrame(rightHalfA)
    await rig.waitForEvents(2)

    // The check is spent: a later title change moves nothing.
    await rig.fake.configure { $0.windows[handle]?.frame = start }
    await rig.emit(.titleChanged(handle, "Docs other"))
    await rig.waitForEvents(3)
    #expect(await rig.frame() == start)
}

@Test func titleChangeAfterTheWindowWasMovedIsIgnored() async {
    let desk = layout("Desk", [slot(.rightHalf, title: "*Docs*")])
    let rig = await Rig()
    await rig.engine.start(config: config(layouts: [desk]))
    await rig.engine.applyLayout(named: "Desk")
    let created = titled(window(1, frame: start), "Untitled")
    await rig.fake.configure { $0.windows[created.handle] = created }
    await rig.emit(.windowCreated(created))
    // The user drags the window, then the app sets the title.
    await rig.fake.configure { $0.windows[handle]?.frame = rect(200, 200, 400, 300); $0.windows[handle]?.title = "Docs" }
    await rig.emit(.windowMoved(handle))
    await rig.emit(.titleChanged(handle, "Docs"))
    await rig.waitForEvents(3)
    #expect(await rig.frame() == rect(200, 200, 400, 300))
}

@Test func aShortcutEndsANewWindowsTitleCheck() async {
    let desk = layout("Desk", [slot(.rightHalf, title: "*Docs*")])
    let rig = await Rig()
    await rig.engine.start(config: config(layouts: [desk]))
    await rig.engine.applyLayout(named: "Desk")
    let created = titled(window(1, frame: start), "Untitled")
    await rig.fake.configure { $0.windows[created.handle] = created }
    await rig.emit(.windowCreated(created))
    await rig.waitForEvents(1)
    await rig.engine.perform(.leftHalf)
    // The title that would match comes within the second, after the user placed the window.
    await rig.fake.configure { $0.windows[handle]?.title = "Docs" }
    await rig.emit(.titleChanged(handle, "Docs"))
    await rig.waitForEvents(2)
    #expect(await rig.frame() == leftHalfA)
}

@Test(.timeLimit(.minutes(1))) func aShortcutWhileATitlePlacementReadsTheWindowWins() async {
    let desk = layout("Desk", [slot(.rightHalf, title: "*Docs*")])
    let rig = await Rig()
    await rig.engine.start(config: config(layouts: [desk]))
    await rig.engine.applyLayout(named: "Desk")
    let created = titled(window(1, frame: start), "Untitled")
    await rig.fake.configure { $0.windows[created.handle] = created }
    await rig.emit(.windowCreated(created))
    await rig.waitForEvents(1)
    // The title check has passed and its placement is reading the window when the shortcut comes.
    let reads = FakeGate()
    await rig.fake.configure { $0.windows[handle]?.title = "Docs"; $0.snapshotGate = reads }
    await rig.emit(.titleChanged(handle, "Docs"))
    await rig.fake.waitUntil { _ in reads.waiterCount == 1 }
    // Without the held read, the shortcut's own read would take the gate and wait for it forever; a
    // time limit cannot end that, because a gated call is not cancellable.
    guard reads.waiterCount == 1 else { return reads.open() }
    await rig.engine.perform(.leftHalf)
    reads.open()
    await rig.waitForEvents(2)
    #expect(await rig.frame() == leftHalfA)
}

@Test(.timeLimit(.minutes(1))) func aMoveWhileATitlePlacementResolvesWins() async {
    let desk = layout("Desk", [slot(.rightHalf, title: "*Docs*")])
    let rig = await Rig()
    await rig.engine.start(config: config(layouts: [desk]))
    await rig.engine.applyLayout(named: "Desk")
    let created = titled(window(1, frame: start), "Untitled")
    await rig.fake.configure { $0.windows[created.handle] = created }
    await rig.emit(.windowCreated(created))
    await rig.waitForEvents(1)
    // The title placement's own read passes; the pipeline's Resolve read is held while the user drags.
    let reads = await rig.fake.snapshotCount
    let resolving = await rig.fake.pauseSnapshot(at: reads + 1)
    await rig.fake.configure { $0.windows[handle]?.title = "Docs" }
    await rig.emit(.titleChanged(handle, "Docs"))
    await rig.fake.waitUntil { _ in resolving.waiterCount == 1 }
    let dragged = rect(300, 300, 400, 300)
    await rig.fake.configure { $0.windows[handle]?.frame = dragged }
    await rig.emit(.windowMoved(handle))
    await rig.waitForEvents(2)
    resolving.open()
    await rig.waitForEvents(3)
    #expect(await rig.frame() == dragged)
}

@Test(.timeLimit(.minutes(1))) func aMoveWhileANewWindowsPlacementResolvesWins() async {
    let desk = layout("Desk", [slot(.rightHalf)])
    let rig = await Rig()
    await rig.engine.start(config: config(layouts: [desk]))
    await rig.engine.applyLayout(named: "Desk")
    let created = window(1, frame: start)
    let reads = await rig.fake.snapshotCount
    let resolving = await rig.fake.pauseSnapshot(at: reads)
    await rig.fake.configure { $0.windows[created.handle] = created }
    await rig.emit(.windowCreated(created))
    await rig.fake.waitUntil { _ in resolving.waiterCount == 1 }
    let dragged = rect(300, 300, 400, 300)
    await rig.fake.configure { $0.windows[handle]?.frame = dragged }
    await rig.emit(.windowMoved(handle))
    // The placement counts as an event once it is done, the move once it is judged.
    await rig.waitForEvents(1)
    resolving.open()
    await rig.waitForEvents(2)
    #expect(await rig.frame() == dragged)
}

@Test func applyingALayoutEndsANewWindowsTitleCheck() async {
    let desk = layout("Desk", [slot(.rightHalf, title: "*Docs*"), slot(.leftHalf)])
    let rig = await Rig()
    await rig.engine.start(config: config(layouts: [desk]))
    await rig.engine.applyLayout(named: "Desk")
    let created = titled(window(1, frame: start), "Untitled")
    await rig.fake.configure { $0.windows[created.handle] = created }
    await rig.emit(.windowCreated(created))
    await rig.waitForFrame(leftHalfA)
    await rig.waitForEvents(1)
    // Applied again while the window is still untitled, the layout leaves it on the left.
    await rig.engine.applyLayout(named: "Desk")
    await rig.fake.configure { $0.windows[handle]?.title = "Docs" }
    await rig.emit(.titleChanged(handle, "Docs"))
    await rig.waitForEvents(2)
    #expect(await rig.frame() == leftHalfA)
}

@Test func titleCheckUsesReloadedEntries() async {
    let first = layout("Desk", [slot(.firstThird)])
    let reloaded = layout("Desk", [slot(.lastThird)])
    let rig = await Rig()
    await rig.engine.start(config: config(layouts: [first]))
    await rig.engine.applyLayout(named: "Desk")
    let created = window(1, frame: start)
    await rig.fake.configure { $0.windows[created.handle] = created }
    await rig.emit(.windowCreated(created))
    await rig.waitForFrame(rect(0, 25, 1000.0 / 3, 775))

    await rig.engine.update(config: config(layouts: [reloaded]))
    await rig.clock.advance(by: .milliseconds(500))
    await rig.fake.configure { $0.windows[handle]?.title = "Renamed" }
    await rig.emit(.titleChanged(handle, "Renamed"))
    await rig.waitForFrame(rect(2000.0 / 3, 25, 1000.0 / 3, 775))
}

// MARK: Reloads

@Test func reloadMovesNothing() async {
    let desk = layout("Desk", [slot(.rightHalf)])
    let rig = await Rig(windows: [window(1, frame: start)])
    await rig.engine.start(config: config(layouts: [desk]))
    await rig.engine.applyLayout(named: "Desk")
    let before = await rig.log

    await rig.engine.update(config: config(gap: 20, layouts: [layout("Desk", [slot(.leftHalf)])]))
    #expect(await rig.engine.activeLayoutName == "Desk")
    await rig.engine.update(config: config())
    #expect(await rig.engine.activeLayoutName == nil)
    #expect(await rig.log == before)
    #expect(await rig.frame() == rightHalfA)
}

// MARK: Display changes

private let dock = layout("Dock", displays: ["Built-in", "Desk"], [slot(.firstThird, display: "Desk")])

@Test func dockingAppliesTheClaimingLayout() async {
    let rig = await Rig(windows: [window(1, frame: start)])
    await rig.engine.start(config: config(layouts: [dock]))
    await rig.changeDisplays(to: bothDisplays, eventsHandledAfter: 2)
    await rig.waitForReport { $0 == .displayChangeHandled(moved: 1, failed: 0) }
    #expect(await rig.frame().map { isClose($0, rect(1000, 0, 2000.0 / 3, 1550)) } == true)
    #expect(await rig.engine.activeLayoutName == "Dock")
}

@Test func wakeMovesNothing() async {
    let rig = await Rig(displays: bothDisplays, windows: [window(1, frame: rect(1100, 100, 400, 300))])
    await rig.engine.start(config: config(layouts: [dock]))
    // The display drops out and comes back: the setup is the same.
    await rig.changeDisplays(to: bothDisplays, eventsHandledAfter: 2)
    await rig.waitUntilChangeIsSettled()
    #expect(await rig.log.isEmpty)
    #expect(await rig.frame() == rect(1100, 100, 400, 300))
    #expect(await rig.engine.activeLayoutName == nil)
}

/// A resolution change leaves the setup the same and moves no window: the window keeps its points,
/// so its relative frame changes with nothing to announce it. Recording that frame is the change's
/// job; a stale one comes back as a wrong frame when another display connects and leaves.
@Test(.timeLimit(.minutes(1))) func aChangeThatEndsOnTheSameSetupRecordsWhereTheWindowsAre() async {
    let wide = Display(
        identity: displayA.identity, frame: rect(0, 0, 2000, 800), visibleFrame: rect(0, 25, 2000, 775)
    )
    let rig = await Rig(windows: [window(1, frame: start)])
    await rig.engine.start(config: config())
    await rig.changeDisplays(to: [wide], eventsHandledAfter: 2)
    let setup = DisplaySetup([displayA])
    let recorded = await pollUntilLastKnown(rig, handle, setup) { $0 == start.relative(to: wide.visibleFrame) }
    #expect(recorded)

    await rig.changeDisplays(to: [wide, displayB], eventsHandledAfter: 4)
    await rig.waitForChanges(1)
    await rig.changeDisplays(to: [wide], eventsHandledAfter: 6)
    await rig.waitForChanges(2)
    #expect(await rig.frame().map { isClose($0, start) } == true)
}

/// The unchanged-setup read records the windows against the new geometry. A change that begins
/// while that read is held must see that geometry as where it began from, not the one before the
/// first change, or its rules recognise placements against displays that are gone.
@Test(.timeLimit(.minutes(1))) func aChangeBeginningDuringTheUnchangedSetupReadStartsFromTheRecordedGeometry() async {
    let wide = Display(
        identity: displayA.identity, frame: rect(0, 0, 2000, 800), visibleFrame: rect(0, 25, 2000, 775)
    )
    let rig = await Rig(windows: [window(1, frame: start)])
    await rig.engine.start(config: config())
    await rig.fake.configure { $0.displays = [wide] }
    let reads = FakeGate()
    await rig.fake.configure { $0.visibleWindowsGate = reads }
    await rig.emit(.reconfigurationBegan)
    await rig.emit(.reconfigurationEnded)
    await rig.waitForEvents(2)
    await rig.clock.waitForSleepers(1)
    await rig.clock.advance(by: quiet)
    await rig.fake.waitUntil { _ in reads.waiterCount == 1 }
    // Another change begins while the settled change reads the windows into the new geometry.
    await rig.emit(.reconfigurationBegan)
    await rig.waitForEvents(3)
    reads.open()
    await rig.engine.rulesTask?.value
    #expect(await rig.engine.changeOrigin == [wide])
    // The stopped run leaves the stored setup to the change that follows.
    #expect(await rig.engine.memory.read().lastDisplays == [displayA])
}

/// A change that settles while startup's seed reads the windows stores its own setup. Startup does
/// not put the setup it read back, or the next launch would run the rules again for a change
/// already handled.
@Test(.timeLimit(.minutes(1))) func aChangeSettledDuringTheStartSeedKeepsItsSetupStored() async {
    let rig = await Rig(windows: [window(1, frame: start)], focused: nil)
    let seed = FakeGate()
    await rig.fake.configure { $0.visibleWindowsGate = seed }
    let starting = Task { await rig.engine.start(config: config()) }
    await rig.fake.waitUntil { _ in seed.waiterCount == 1 }
    await rig.changeDisplays(to: bothDisplays, eventsHandledAfter: 2)
    await rig.waitForChanges(1)
    #expect(await rig.engine.memory.read().lastDisplays == bothDisplays)
    seed.open()
    await starting.value
    #expect(await rig.engine.memory.read().lastDisplays == bothDisplays)
}

@Test func windowMovesPushTheSettleDeadline() async {
    let rig = await Rig(displays: bothDisplays, windows: [window(1, frame: rect(1100, 100, 400, 300))])
    await rig.engine.start(config: config())
    await rig.fake.configure { $0.displays = [displayA] }
    await rig.emit(.reconfigurationBegan)
    await rig.emit(.reconfigurationEnded)
    await rig.waitForEvents(2)
    await rig.clock.waitForSleepers(1)
    await rig.clock.advance(by: .seconds(1))

    // macOS is still relocating windows: the quiet period starts over.
    await rig.emit(.windowMoved(handle))
    await rig.waitForEvents(3)
    await rig.clock.waitForSleepers(1)
    await rig.clock.advance(by: .milliseconds(500))
    // The wait that was due now has been replaced by one that ends 1.5 s after the move.
    #expect(rig.clock.sleeperCount == 1)
    #expect(await rig.engine.isFrozen)
    await rig.clock.advance(by: .seconds(1))
    await rig.waitUntilChangeIsSettled()
    await rig.waitForChanges(1)
}

@Test func aLostEndedCallbackCountsAsEndedAfterTenSeconds() async {
    let rig = await Rig(displays: bothDisplays, windows: [window(1, frame: leftHalfB)])
    await rig.engine.start(config: config())
    await rig.fake.configure { $0.displays = [displayA]; $0.windows[handle]?.frame = rect(0, 25, 600, 500) }
    await rig.emit(.reconfigurationBegan)
    await rig.waitForEvents(1)
    await rig.clock.waitForSleepers(1)
    await rig.clock.advance(by: .seconds(10))
    // Counted as ended at 10 s: the quiet period follows.
    await rig.waitForEvents(1)
    await rig.clock.waitForSleepers(1)
    await rig.clock.advance(by: quiet)
    await rig.waitForReport { $0 == .displayChangeHandled(moved: 1, failed: 0) }
    #expect(await rig.frame() == leftHalfA)
}

@Test(.timeLimit(.minutes(1))) func aWindowMoveDoesNotStretchTheTenSecondCap() async {
    let rig = await Rig(displays: bothDisplays, windows: [window(1, frame: leftHalfB)])
    await rig.engine.start(config: config())
    await rig.fake.configure { $0.displays = [displayA]; $0.windows[handle]?.frame = rect(0, 25, 600, 500) }
    await rig.emit(.reconfigurationBegan)
    await rig.waitForEvents(1)
    await rig.clock.waitForSleepers(1)
    // The ended callback is lost; a window moves at 9 s.
    await rig.clock.advance(by: .seconds(9))
    await rig.emit(.windowMoved(handle))
    await rig.waitForEvents(2)
    await rig.clock.waitForSleepers(1)
    // The reconfiguration closes at 10 s, counted from when it opened.
    await rig.clock.advance(by: .seconds(1))
    await rig.clock.waitForSleepers(1)
    #expect(await rig.engine.tracker.deadline == .seconds(10) + quiet)
    await rig.clock.advance(by: quiet)
    await rig.waitForReport { $0 == .displayChangeHandled(moved: 1, failed: 0) }
}

@Test func returningSetupRestoresRememberedFrames() async {
    let onB = window(1, frame: rect(1100, 100, 400, 300))
    let onA = window(2, frame: start)
    let rig = await Rig(displays: bothDisplays, windows: [onB, onA], focused: nil)
    await rig.engine.start(config: config())

    // Undock; macOS moves the window that was on B and shoves the other, and tells us.
    await rig.fake.configure {
        $0.displays = [displayA]
        $0.windows[onB.handle]?.frame = rect(50, 50, 300, 300)
        $0.windows[onA.handle]?.frame = rect(300, 300, 200, 200)
    }
    await rig.emit(.reconfigurationBegan)
    await rig.emit(.windowMoved(onB.handle))
    await rig.emit(.windowMoved(onA.handle))
    await rig.emit(.reconfigurationEnded)
    await rig.waitForEvents(4)
    await rig.clock.waitForSleepers(1)
    await rig.clock.advance(by: quiet)
    await rig.waitForReport { if case .displayChangeHandled = $0 { true } else { false } }

    // Dock again; macOS leaves everything where the undock put it.
    await rig.changeDisplays(to: bothDisplays, eventsHandledAfter: 6)
    await rig.waitForChanges(2)
    #expect(await rig.frame(of: onB.handle).map { isClose($0, rect(1100, 100, 400, 300)) } == true)
    #expect(await rig.frame(of: onA.handle).map { isClose($0, start) } == true)
}

@Test func untouchedWindowCarriesOverAfterUndock() async {
    let rig = await Rig(displays: bothDisplays, windows: [window(1, frame: leftHalfB)])
    await rig.engine.start(config: config())
    await rig.fake.configure { $0.windows[handle]?.frame = rect(0, 25, 600, 500) }
    await rig.changeDisplays(to: [displayA], eventsHandledAfter: 2)
    await rig.waitForReport { $0 == .displayChangeHandled(moved: 1, failed: 0) }
    #expect(await rig.frame() == leftHalfA)
}

@Test(.timeLimit(.minutes(1))) func aDisplayChangeCountsItsFailuresWithoutAnOverlay() async {
    let slow = window(5, frame: rect(1500, 500, 400, 300), pid: 50, bundleID: "com.c")
    let rig = await Rig(displays: bothDisplays, windows: [strayB1, slow], focused: nil) { $0.hung = [50] }
    await rig.engine.start(config: config())
    await rig.fake.configure {
        $0.windows[strayB1.handle]?.frame = rect(50, 50, 300, 300)
        $0.windows[slow.handle]?.frame = rect(400, 400, 300, 300)
    }
    await rig.changeDisplays(to: [displayA], eventsHandledAfter: 2)
    // The hung app's call is waiting on the clock.
    await rig.clock.waitForSleepers(1)
    await rig.clock.advance(by: .milliseconds(500))
    await rig.waitForReport { $0 == .displayChangeHandled(moved: 1, failed: 1) }
    #expect(rig.reports.allSatisfy { if case .failure = $0 { false } else { true } })
}

@Test func aLayoutEndsAtTheNextDisplayChange() async {
    let desk = layout("Desk", [slot(.rightHalf)])
    let rig = await Rig(displays: bothDisplays, windows: [window(1, frame: start)])
    await rig.engine.start(config: config(layouts: [desk]))
    await rig.engine.applyLayout(named: "Desk")
    #expect(await rig.engine.activeLayoutName == "Desk")
    await rig.changeDisplays(to: [displayA], eventsHandledAfter: 2)
    await rig.waitForReport { if case .displayChangeHandled = $0 { true } else { false } }
    #expect(await rig.engine.activeLayoutName == nil)
}

@Test func unobservableAppLeftAlone() async {
    let observed = window(1, frame: leftHalfB, pid: 100, bundleID: "com.a")
    let unobserved = window(2, frame: leftHalfB, pid: 200, bundleID: "com.b")
    let rig = await Rig(displays: bothDisplays, windows: [observed, unobserved])
    await rig.engine.start(config: config())
    await rig.emit(.unobservable(pid: 200, bundleID: "com.b", missing: [.moved]))
    await rig.emit(.unobservable(pid: 200, bundleID: "com.b", missing: [.created]))
    await rig.waitForEvents(2)
    let asleep = rect(0, 25, 600, 500)
    await rig.fake.configure {
        $0.windows[observed.handle]?.frame = asleep
        $0.windows[unobserved.handle]?.frame = asleep
    }
    await rig.changeDisplays(to: [displayA], eventsHandledAfter: 4)
    await rig.waitForReport { $0 == .displayChangeHandled(moved: 1, failed: 0) }
    #expect(await rig.frame(of: observed.handle) == leftHalfA)
    #expect(await rig.frame(of: unobserved.handle) == asleep)
    #expect(rig.reports.filter { $0 == .unobservable(bundleID: "com.b") }.count == 1)
}

@Test func unobservableAppsAreCountedUntilTheyQuit() async {
    let rig = await Rig()
    await rig.engine.start(config: config())
    #expect(await rig.engine.unobservableAppCount == 0)
    await rig.emit(.unobservable(pid: 200, bundleID: "com.b", missing: [.moved]))
    await rig.emit(.unobservable(pid: 200, bundleID: "com.b", missing: [.created]))
    await rig.emit(.unobservable(pid: 300, bundleID: nil, missing: [.created]))
    await rig.waitForEvents(3)
    #expect(await rig.engine.unobservableAppCount == 2)
    await rig.emit(.appQuit(pid: 200))
    await rig.waitForEvents(4)
    #expect(await rig.engine.unobservableAppCount == 1)
}

@Test func unobservableAppGetsNoNewWindowPlacement() async {
    let desk = layout("Desk", [slot(.rightHalf, app: "com.b")])
    let rig = await Rig()
    await rig.engine.start(config: config(layouts: [desk]))
    await rig.engine.applyLayout(named: "Desk")
    await rig.emit(.unobservable(pid: 200, bundleID: "com.b", missing: [.created]))
    let created = window(2, frame: start, pid: 200, bundleID: "com.b")
    await rig.fake.configure { $0.windows[created.handle] = created }
    await rig.emit(.windowCreated(created))
    await rig.waitForEvents(2)
    #expect(await rig.log.isEmpty)
}

// MARK: Start and stop

private func temporaryStore() -> (MemoryStore, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return (MemoryStore(fileURL: directory.appendingPathComponent("memory.json")), directory)
}

@Test func launchRunsRulesWhenTheSetupChanged() async {
    let (store, directory) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let steps: [any AdjustStep] = [GapStep(), MinimumSizeStep(), OnScreenStep()]
    let gapped = config(gap: 10)

    // What the placement looks like on A alone, for comparison.
    let reference = await Rig(windows: [window(1, frame: start)], steps: steps)
    await reference.engine.start(config: gapped)
    await reference.engine.perform(.firstThird)
    let expected = await reference.frame()

    let first = await Rig(displays: bothDisplays, windows: [window(1, frame: rect(1100, 100, 400, 300))], store: store, steps: steps)
    await first.engine.start(config: gapped)
    await first.engine.perform(.firstThird)
    await first.emit(.windowMoved(handle))
    await first.waitForEvents(1)
    await first.engine.stop()

    // Next launch: B is gone and macOS put the window somewhere on A.
    let second = await Rig(windows: [window(1, frame: rect(300, 300, 400, 300))], store: store, steps: steps)
    await second.engine.start(config: gapped)
    #expect(await second.frame() == expected)
    // A's first third with the gap: 10 from the screen edges, 5 on the inner edge.
    #expect(expected.map { isClose($0, rect(10, 35, 1000.0 / 3 - 15, 755)) } == true)
    await second.waitForReport { $0 == .displayChangeHandled(moved: 1, failed: 0) }
}

@Test func launchWithTheSameSetupMovesNothing() async {
    let (store, directory) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = await Rig(windows: [window(1, frame: start)], store: store)
    await first.engine.start(config: config())
    await first.engine.stop()
    let second = await Rig(windows: [window(1, frame: start)], store: store)
    await second.engine.start(config: config())
    #expect(await second.log.isEmpty)
    await second.waitForReport { if case .memory = $0 { true } else { false } }
    #expect(second.reports.count == 1)
    if case .memory(.loaded) = second.reports.first {} else { Issue.record("Expected the saved memory to load; got \(second.reports)") }
}

@Test func theRememberedLayoutIsLookedUpByNameAtLaunch() async {
    let (store, directory) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let desk = layout("Desk", [slot(.rightHalf)])
    let first = await Rig(store: store)
    await first.engine.start(config: config(layouts: [desk]))
    await first.engine.applyLayout(named: "Desk")
    await first.engine.stop()

    let kept = await Rig(store: store)
    await kept.engine.start(config: config(layouts: [desk]))
    #expect(await kept.engine.activeLayoutName == "Desk")
    let gone = await Rig(store: store)
    await gone.engine.start(config: config())
    #expect(await gone.engine.activeLayoutName == nil)
}

@Test func startAndStopObserveAndSave() async {
    let (store, directory) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let rig = await Rig(windows: [window(1, frame: start)], store: store)
    await rig.engine.start(config: config())
    #expect(await rig.fake.startObservingCount == 1)
    await rig.engine.stop()
    #expect(await rig.fake.stopObservingCount == 1)
    if case .loaded = store.load() {} else { Issue.record("Expected stop to save the memory") }
}

@Test func aDestroyedWindowIsForgotten() async {
    let rig = await Rig(windows: [window(1, frame: start)])
    await rig.engine.start(config: config())
    await rig.engine.perform(.leftHalf)
    let remembered = await rig.engine.memory.read()
    #expect(remembered.placed[handle] != nil)
    #expect(remembered.lastKnown.values.contains { $0[handle] != nil })

    await rig.emit(.windowDestroyed(handle))
    await rig.waitForEvents(1)
    let after = await rig.engine.memory.read()
    #expect(after.placed[handle] == nil)
    #expect(after.lastKnown.values.allSatisfy { $0[handle] == nil })
}

@Test func aQuitAppIsForgotten() async {
    let rig = await Rig(windows: [window(1, frame: start)])
    await rig.engine.start(config: config())
    await rig.engine.perform(.leftHalf)
    await rig.emit(.appQuit(pid: 100))
    await rig.waitForEvents(1)
    let after = await rig.engine.memory.read()
    #expect(after.placed.isEmpty)
    #expect(after.lastKnown.isEmpty)
}

// MARK: Memory across launches

private let saveDate = Date(timeIntervalSince1970: 1_800_000_000)

/// A memory saved while the app of `handle` ran, last on A alone: it has the window on B for
/// the docked setup, a placement and a restore chain.
private func rememberedOnB(savedAt: Date?) -> WindowMemory {
    var memory = WindowMemory(lastDisplays: [displayA], savedAt: savedAt)
    memory.recordLastKnown(handle, frame: leftHalfB, display: displayB, setup: DisplaySetup(bothDisplays))
    memory.openChain(handle, before: start, on: displayA)
    memory.recordPlaced(handle, PlacedRecord(
        action: .leftHalf, layout: nil, placement: .leftHalf, cycleStep: 0, achieved: leftHalfA, display: displayA.identity
    ))
    return memory
}

private func storeHolding(_ memory: WindowMemory) throws -> (MemoryStore, URL) {
    let (store, directory) = temporaryStore()
    try store.save(memory)
    return (store, directory)
}

@Test func aWindowOfAnAppRunningSinceTheSaveIsRemembered() async throws {
    let (store, directory) = try storeHolding(rememberedOnB(savedAt: saveDate))
    defer { try? FileManager.default.removeItem(at: directory) }
    let rig = await Rig(displays: bothDisplays, windows: [window(1, frame: start)], store: store) {
        $0.launched = [100: saveDate.addingTimeInterval(-60)]
    }
    await rig.engine.start(config: config())
    // Rule 2: the docked setup was seen before, so the window goes back to where it was on it.
    #expect(await rig.frame().map { isClose($0, leftHalfB) } == true)
    #expect(await rig.engine.memory.read().restore[handle] != nil)
}

@Test func aWindowOfAnAppLaunchedSinceTheSaveIsForgotten() async throws {
    let (store, directory) = try storeHolding(rememberedOnB(savedAt: saveDate))
    defer { try? FileManager.default.removeItem(at: directory) }
    // The pid now belongs to an app launched after the memory was saved, as after a reboot.
    let rig = await Rig(displays: bothDisplays, windows: [window(1, frame: start)], store: store) {
        $0.launched = [100: saveDate.addingTimeInterval(60)]
    }
    await rig.engine.start(config: config())
    // Rule 2 has nothing for it: the window stays where it is.
    #expect(await rig.log.isEmpty)
    #expect(await rig.frame() == start)
    let memory = await rig.engine.memory.read()
    #expect(memory.placed[handle] == nil)
    #expect(memory.restore[handle] == nil)
}

@Test func aWindowOfAnAppThatIsGoneIsForgotten() async throws {
    let gone = WindowHandle(pid: 300, windowID: 9, isStable: true)
    var memory = WindowMemory(lastDisplays: [displayA], savedAt: saveDate)
    memory.openChain(gone, before: start, on: displayA)
    memory.recordLastKnown(gone, frame: start, display: displayA, setup: DisplaySetup(bothDisplays))
    memory.openChain(handle, before: start, on: displayA)
    let (store, directory) = try storeHolding(memory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let rig = await Rig(windows: [window(1, frame: start)], store: store)
    await rig.engine.start(config: config())
    let after = await rig.engine.memory.read()
    #expect(after.restore[gone] == nil)
    #expect(after.lastKnown(gone, setup: DisplaySetup(bothDisplays)) == nil)
    #expect(after.restore[handle] != nil)
}

@Test func aMemoryWithoutASaveDateForgetsEveryWindow() async throws {
    let (store, directory) = try storeHolding(rememberedOnB(savedAt: nil))
    defer { try? FileManager.default.removeItem(at: directory) }
    let rig = await Rig(displays: bothDisplays, windows: [window(1, frame: start)], store: store)
    await rig.engine.start(config: config())
    #expect(await rig.log.isEmpty)
    #expect(await rig.engine.memory.read().restore[handle] == nil)
}

@Test func aSettledDisplayChangeIsSaved() async {
    let (store, directory) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let rig = await Rig(displays: bothDisplays, windows: [window(1, frame: leftHalfB)], store: store)
    await rig.engine.start(config: config())
    await rig.fake.configure { $0.windows[handle]?.frame = rect(0, 25, 600, 500) }
    await rig.changeDisplays(to: [displayA], eventsHandledAfter: 2)
    await rig.waitForReport { if case .displayChangeHandled = $0 { true } else { false } }
    guard case .loaded(let saved) = store.load() else {
        Issue.record("Expected the settled change to be saved")
        return
    }
    #expect(saved.lastDisplays == [displayA])
}

@Test func anActivatedLayoutIsSaved() async {
    let (store, directory) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let desk = layout("Desk", [slot(.rightHalf)])
    let rig = await Rig(windows: [window(1, frame: start)], store: store)
    await rig.engine.start(config: config(layouts: [desk]))
    await rig.engine.applyLayout(named: "Desk")
    guard case .loaded(let saved) = store.load() else {
        Issue.record("Expected the active layout to be saved")
        return
    }
    #expect(saved.activeLayout == "Desk")
}

// MARK: Settling and rules runs

/// Two windows on B that macOS moved to A when B went away; each ends where its relative
/// position on B puts it on A.
private let strayB1 = window(1, frame: rect(1100, 100, 400, 300))
private let strayB2 = window(2, frame: rect(1500, 500, 400, 300))
private let strayA1 = rect(50, 75, 200, 150)
private let strayA2 = rect(250, 275, 200, 150)

@Test(.timeLimit(.minutes(1))) func aStrayEndedDuringTheRulesDoesNotStopThem() async {
    let rig = await Rig(displays: bothDisplays, windows: [strayB1, strayB2], focused: nil)
    await rig.engine.start(config: config())
    await rig.fake.configure {
        $0.displays = [displayA]
        $0.windows[strayB1.handle]?.frame = rect(50, 50, 300, 300)
        $0.windows[strayB2.handle]?.frame = rect(400, 400, 300, 300)
    }
    // The first write is held, so the rules are running when the stray callback arrives.
    let gate = await rig.fake.pause(beforeCall: 0)
    await rig.emit(.reconfigurationBegan)
    await rig.emit(.reconfigurationEnded)
    await rig.waitForEvents(2)
    await rig.clock.waitForSleepers(1)
    await rig.clock.advance(by: quiet)
    await rig.fake.waitUntil { _ in gate.waiterCount == 1 }
    await rig.emit(.reconfigurationEnded)
    await rig.waitForEvents(3)
    gate.open()
    await rig.waitForReport { $0 == .displayChangeHandled(moved: 2, failed: 0) }
    #expect(await rig.frame(of: strayB1.handle).map { isClose($0, strayA1) } == true)
    #expect(await rig.frame(of: strayB2.handle).map { isClose($0, strayA2) } == true)
    #expect(await rig.engine.isFrozen == false)
}

@Test(.timeLimit(.minutes(1))) func aReconfigurationDuringTheRulesReadsStopsTheRun() async {
    let rig = await Rig(displays: bothDisplays, windows: [strayB1], focused: nil)
    await rig.engine.start(config: config())
    await rig.fake.configure { $0.displays = [displayA]; $0.windows[strayB1.handle]?.frame = rect(50, 50, 300, 300) }
    let reads = FakeGate()
    await rig.fake.configure { $0.visibleWindowsGate = reads }
    await rig.emit(.reconfigurationBegan)
    await rig.emit(.reconfigurationEnded)
    await rig.waitForEvents(2)
    await rig.clock.waitForSleepers(1)
    await rig.clock.advance(by: quiet)
    await rig.fake.waitUntil { _ in reads.waiterCount == 1 }
    // Another change begins while the rules are reading the windows.
    await rig.emit(.reconfigurationBegan)
    await rig.waitForEvents(3)
    reads.open()
    await rig.engine.rulesTask?.value
    #expect(await rig.log.isEmpty)
    #expect(await rig.engine.isFrozen)
    #expect(rig.reports.allSatisfy { if case .displayChangeHandled = $0 { false } else { true } })
}

@Test(.timeLimit(.minutes(1))) func aReconfigurationDuringALayoutsReadsStopsTheLayout() async {
    let desk = layout("Desk", [slot(.rightHalf)])
    let rig = await Rig(windows: [window(1, frame: start)])
    await rig.engine.start(config: config(layouts: [desk]))
    let reads = FakeGate()
    await rig.fake.configure { $0.visibleWindowsGate = reads }
    let applying = Task { await rig.engine.applyLayout(named: "Desk") }
    await rig.fake.waitUntil { _ in reads.waiterCount == 1 }
    await rig.emit(.reconfigurationBegan)
    await rig.waitForEvents(1)
    reads.open()
    await applying.value
    #expect(await rig.log.isEmpty)
    #expect(await rig.frame() == start)
    // A stopped run neither reports nor activates: a report sent after it would come after any such.
    #expect(await rig.engine.activeLayoutName == nil)
    await rig.fake.configure { $0.accessibilityGranted = false }
    await rig.engine.perform(.leftHalf)
    await rig.waitForReport { $0 == .failure(.permissionMissing, display: nil) }
    #expect(rig.reports.allSatisfy { if case .layoutApplied = $0 { false } else { true } })
}

@Test(.timeLimit(.minutes(1))) func interruptedRulesRunAgainWhenTheSetupIsBackWhereItBegan() async {
    let rig = await Rig(displays: bothDisplays, windows: [strayB1], focused: nil)
    await rig.engine.start(config: config())
    await rig.fake.configure { $0.displays = [displayA]; $0.windows[strayB1.handle]?.frame = rect(50, 50, 300, 300) }
    let gate = await rig.fake.pause(beforeCall: 0)
    await rig.emit(.reconfigurationBegan)
    await rig.emit(.reconfigurationEnded)
    await rig.waitForEvents(2)
    await rig.clock.waitForSleepers(1)
    await rig.clock.advance(by: quiet)
    await rig.fake.waitUntil { _ in gate.waiterCount == 1 }

    // B comes back before the undock's first write is made.
    await rig.fake.configure { $0.displays = bothDisplays }
    await rig.emit(.reconfigurationBegan)
    await rig.emit(.reconfigurationEnded)
    await rig.waitForEvents(4)
    gate.open()
    await rig.clock.waitForSleepers(1)
    await rig.clock.advance(by: quiet)
    await rig.waitForReport { if case .displayChangeHandled = $0 { true } else { false } }
    // The window was left half way: the remembered frame brings it back.
    #expect(await rig.frame(of: strayB1.handle).map { isClose($0, rect(1100, 100, 400, 300)) } == true)
}

// MARK: Last-known frames

@Test(.timeLimit(.minutes(1))) func aFrameJudgedDuringTheWriteIsLastKnown() async {
    let free = rect(1100, 100, 400, 300)
    let reference = await Rig(displays: bothDisplays, windows: [window(1, frame: free)])
    await reference.engine.start(config: config())
    await reference.engine.perform(.leftHalf)
    let calls = await reference.log.count

    let rig = await Rig(displays: bothDisplays, windows: [window(1, frame: free)])
    await rig.engine.start(config: config())
    // Hold the session's last call, so the event is judged while the write is still running.
    let gate = await rig.fake.pause(beforeCall: calls - 1)
    let acting = Task { await rig.engine.perform(.leftHalf) }
    await rig.fake.waitUntil { _ in gate.waiterCount == 1 }
    await rig.emit(.windowMoved(handle))
    await rig.waitForEvents(1)
    let known = await rig.engine.memory.read().lastKnown(handle, setup: DisplaySetup(bothDisplays))
    #expect(known?.display == displayB.identity)
    #expect(known?.relative == leftHalfB.relative(to: displayB.visibleFrame))
    gate.open()
    await acting.value

    // macOS moves the window when B goes away; the left half it was in carries over.
    await rig.fake.configure { $0.windows[handle]?.frame = rect(50, 50, 300, 300) }
    await rig.changeDisplays(to: [displayA], eventsHandledAfter: 3)
    await rig.waitForChanges(1)
    #expect(await rig.frame() == leftHalfA)
}

@Test func whereAnActionLeavesAWindowIsLastKnown() async {
    let rig = await Rig(displays: bothDisplays, windows: [window(1, frame: rect(1100, 100, 400, 300))])
    await rig.engine.start(config: config())
    await rig.engine.perform(.leftHalf)
    let known = await rig.engine.memory.read().lastKnown(handle, setup: DisplaySetup(bothDisplays))
    #expect(known?.relative == leftHalfB.relative(to: displayB.visibleFrame))
}

@Test func whereALayoutLeavesWindowsIsLastKnown() async {
    let desk = layout("Desk", [slot(.rightHalf)])
    let rig = await Rig(windows: [window(1, frame: start)])
    await rig.engine.start(config: config(layouts: [desk]))
    await rig.engine.applyLayout(named: "Desk")
    let known = await rig.engine.memory.read().lastKnown(handle, setup: DisplaySetup([displayA]))
    #expect(known?.relative == rightHalfA.relative(to: displayA.visibleFrame))
}

@Test(.timeLimit(.minutes(1))) func aLateFrameForADestroyedWindowRecordsNothing() async {
    let rig = await Rig(windows: [window(1, frame: start)])
    await rig.engine.start(config: config())
    let reads = FakeGate()
    await rig.fake.configure { $0.snapshotGate = reads; $0.windows[handle]?.frame = rect(200, 200, 300, 300) }
    await rig.emit(.windowMoved(handle))
    await rig.fake.waitUntil { _ in reads.waiterCount == 1 }
    // A read after the window's end finds no window.
    await rig.fake.configure { $0.windows[handle] = nil }
    await rig.emit(.windowDestroyed(handle))
    await rig.waitForEvents(1)
    reads.open()
    await rig.waitForEvents(2)
    let after = await rig.engine.memory.read()
    #expect(after.lastKnown.values.allSatisfy { $0[handle] == nil })
    #expect(await !rig.engine.owner.knows(handle))
}

@Test(.timeLimit(.minutes(1))) func aFrameReadBeforeAWindowsEndIsForgottenWithIt() async {
    let rig = await Rig(windows: [window(1, frame: start)])
    await rig.engine.start(config: config())
    // The read is done and its result held when the window is destroyed.
    let late = FakeGate()
    await rig.fake.configure { $0.snapshotLateGate = late; $0.windows[handle]?.frame = rect(200, 200, 300, 300) }
    await rig.emit(.windowMoved(handle))
    await rig.fake.waitUntil { _ in late.waiterCount == 1 }
    await rig.fake.configure { $0.windows[handle] = nil }
    await rig.emit(.windowDestroyed(handle))
    await rig.waitForEvents(1)
    late.open()
    await rig.waitForEvents(2)
    let after = await rig.engine.memory.read()
    #expect(after.lastKnown.values.allSatisfy { $0[handle] == nil })
    #expect(await !rig.engine.owner.knows(handle))
}

@Test(.timeLimit(.minutes(1))) func aLateFrameForAQuitAppRecordsNothing() async {
    let rig = await Rig(windows: [window(1, frame: start)])
    await rig.engine.start(config: config())
    let reads = FakeGate()
    await rig.fake.configure { $0.snapshotGate = reads; $0.windows[handle]?.frame = rect(200, 200, 300, 300) }
    await rig.emit(.windowMoved(handle))
    await rig.fake.waitUntil { _ in reads.waiterCount == 1 }
    // A read after the app's quit finds none of its windows.
    await rig.fake.configure { $0.windows[handle] = nil }
    await rig.emit(.appQuit(pid: 100))
    await rig.waitForEvents(1)
    reads.open()
    await rig.waitForEvents(2)
    let after = await rig.engine.memory.read()
    #expect(after.lastKnown.isEmpty)
    #expect(await !rig.engine.owner.knows(handle))
}

@Test(.timeLimit(.minutes(1))) func aQuitAppIsForgottenByTheOwner() async {
    let rig = await Rig(windows: [window(1, frame: start)])
    await rig.engine.start(config: config())
    await rig.engine.perform(.rightHalf)
    #expect(await rig.isTouched())
    await rig.emit(.appQuit(pid: 100))
    await rig.waitForEvents(1)
    #expect(await !rig.engine.owner.knows(handle))
    #expect(await !rig.isTouched())
}

@Test func aWindowMovedWhileItWasPlacedIsNotPlacedAgainByATitleChange() async {
    let desk = layout("Desk", [slot(.rightHalf, title: "*Docs*")])
    let rig = await Rig()
    await rig.engine.start(config: config(layouts: [desk]))
    await rig.engine.applyLayout(named: "Desk")
    let created = titled(window(1, frame: start), "Docs")
    // Something drags the window during the placement's third call.
    await rig.fake.configure {
        $0.windows[created.handle] = created
        $0.beforeCall = [2: { $0.frame = rect(333, 444, 222, 111) }]
    }
    await rig.emit(.windowCreated(created))
    await rig.fake.waitUntil { $0.callLog.last == "end" }
    await rig.waitForEvents(1)
    #expect(await rig.isTouched())

    let dragged = await rig.frame()
    await rig.emit(.titleChanged(handle, "Docs again"))
    await rig.waitForEvents(2)
    #expect(await rig.frame() == dragged)
}

// MARK: Unobservable apps

private let slowApp = UnobservableApp(pid: 200, bundleID: "com.b", missing: [.moved])

@Test(.timeLimit(.minutes(1))) func anAppUnobservableAtLaunchIsLeftOutOfTheLaunchRules() async {
    let (store, directory) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let other = window(2, frame: leftHalfB, pid: 200, bundleID: "com.b")
    let first = await Rig(displays: bothDisplays, windows: [other], store: store)
    await first.engine.start(config: config())
    await first.engine.stop()

    // The next launch finds B gone, and finds the app unobservable while it starts observing.
    var moved = other
    moved.frame = rect(0, 25, 600, 500)
    let second = await Rig(windows: [moved], store: store) {
        $0.unobserved = [.init(pid: 200, bundleID: "com.b", missing: [.moved])]
    }
    await second.engine.start(config: config())
    #expect(await second.frame(of: other.handle) == moved.frame)
    #expect(await second.log.isEmpty)
    await second.waitForReport { $0 == .unobservable(bundleID: "com.b") }
}

@Test(.timeLimit(.minutes(1))) func aReconfigurationDuringStartStopsItsRules() async {
    let (store, directory) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = await Rig(displays: bothDisplays, windows: [strayB1], store: store)
    await first.engine.start(config: config())
    await first.engine.stop()

    let second = await Rig(windows: [window(1, frame: rect(50, 50, 300, 300))], store: store)
    let reads = FakeGate()
    await second.fake.configure { $0.visibleWindowsGate = reads }
    let starting = Task { await second.engine.start(config: config()) }
    await second.fake.waitUntil { _ in reads.waiterCount == 1 }
    await second.emit(.reconfigurationBegan)
    await second.waitForEvents(1)
    reads.open()
    await starting.value
    #expect(await second.log.isEmpty)
    #expect(await second.engine.isFrozen)
}

@Test func anAppMissingOnlyTitleChangesIsHandledNormally() async {
    let desk = layout("Desk", [slot(.rightHalf, app: "com.b")])
    let app = window(2, frame: leftHalfB, pid: 200, bundleID: "com.b")
    let rig = await Rig(displays: bothDisplays, windows: [app]) {
        $0.unobserved = [.init(pid: 200, bundleID: "com.b", missing: [.titleChanged])]
    }
    await rig.engine.start(config: config(layouts: [desk]))
    await rig.fake.configure { $0.windows[app.handle]?.frame = rect(0, 25, 600, 500) }
    await rig.changeDisplays(to: [displayA], eventsHandledAfter: 2)
    await rig.waitForReport { $0 == .displayChangeHandled(moved: 1, failed: 0) }
    #expect(await rig.frame(of: app.handle) == leftHalfA)

    await rig.engine.applyLayout(named: "Desk")
    let created = window(3, frame: start, pid: 200, bundleID: "com.b")
    await rig.fake.configure { $0.windows[created.handle] = created }
    await rig.emit(.windowCreated(created))
    await rig.waitForFrame(rightHalfA, of: created.handle)
}

@Test func anAppMissingCreationsIsStillHandledByTheRules() async {
    let app = window(2, frame: leftHalfB, pid: 200, bundleID: "com.b")
    let rig = await Rig(displays: bothDisplays, windows: [app]) {
        $0.unobserved = [.init(pid: 200, bundleID: "com.b", missing: [.created])]
    }
    await rig.engine.start(config: config())
    await rig.fake.configure { $0.windows[app.handle]?.frame = rect(0, 25, 600, 500) }
    await rig.changeDisplays(to: [displayA], eventsHandledAfter: 2)
    await rig.waitForReport { $0 == .displayChangeHandled(moved: 1, failed: 0) }
    #expect(await rig.frame(of: app.handle) == leftHalfA)
}

@Test func restartingObservationRefreshesTheUnobservableApps() async {
    let rig = await Rig(windows: [window(1, frame: start)]) {
        $0.unobserved = [.init(pid: 200, bundleID: "com.b", missing: [.moved])]
    }
    await rig.engine.start(config: config())
    await rig.fake.configure { $0.unobserved = [.init(pid: 300, bundleID: "com.c", missing: [.created])] }
    await rig.engine.restartObserving()
    #expect(await rig.fake.startObservingCount == 2)
    #expect(await rig.fake.stopObservingCount == 1)
    #expect(await rig.engine.unobservable == [300: [.created]])
    await rig.waitForReport { $0 == .unobservable(bundleID: "com.c") }
    #expect(rig.reports.filter { $0 == .unobservable(bundleID: "com.b") }.count == 1)
    // The event consumer carries on.
    await rig.emit(.appLaunched(pid: 5, bundleID: nil))
    await rig.waitForEvents(1)
}

// MARK: Failures and saving

@Test(.timeLimit(.minutes(1))) func aHungFocusedAppIsNotReportedAsNoWindow() async {
    let rig = await Rig(windows: [window(1, frame: start)]) { $0.hung = [100] }
    await rig.engine.start(config: config())
    let acting = Task { await rig.engine.perform(.leftHalf) }
    await rig.clock.waitForSleepers(1)
    await rig.clock.advance(by: .milliseconds(500))
    await acting.value
    await rig.waitForReport { $0 == .failure(.notResponding(app: "The app"), display: nil) }
}

@Test func aFailedSaveIsReported() async {
    let (store, directory) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let rig = await Rig(windows: [window(1, frame: start)], store: store)
    await rig.engine.start(config: config())
    // Another version of Tafl has written the file since the load.
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? Data(#"{"version": 99}"#.utf8).write(to: directory.appendingPathComponent("memory.json"))
    await rig.engine.save()
    await rig.waitForReport { $0 == .memorySaveFailed }
}

// MARK: Edges of the settle, the runs, the seed and the restart

@Test(.timeLimit(.minutes(1))) func aReconfigurationBeginningAtTheDeadlineIsNotSettledOver() async {
    for _ in 0..<20 {
        let rig = await Rig(displays: bothDisplays, windows: [strayB1], focused: nil)
        await rig.engine.start(config: config())
        await rig.fake.configure { $0.displays = [displayA]; $0.windows[strayB1.handle]?.frame = rect(50, 50, 300, 300) }
        await rig.emit(.reconfigurationBegan)
        await rig.emit(.reconfigurationEnded)
        await rig.waitForEvents(2)
        await rig.clock.waitForSleepers(1)
        let waiting = await rig.engine.settleTask
        // The quiet period ends just as the next reconfiguration begins.
        await rig.clock.advance(by: quiet)
        await rig.emit(.reconfigurationBegan)
        await rig.waitForEvents(3)
        await waiting?.value
        await rig.engine.rulesTask?.value
        // Whatever the order, the change that began last is still open and still frozen.
        #expect(await rig.engine.tracker.isChanging)
        #expect(await rig.engine.isFrozen)
    }
}

@Test(.timeLimit(.minutes(1))) func aWindowDraggedWhileTheRestOfALayoutRunsKeepsItsDraggedFrame() async {
    let a = window(1, frame: start, pid: 100, bundleID: "com.a")
    let slow = window(3, frame: start, pid: 50, bundleID: "com.c")
    let desk = layout("Work", [slot(.leftHalf, app: "com.a"), slot(.topHalf, app: "com.c")])
    let rig = await Rig(windows: [a, slow], focused: nil) { $0.hung = [50] }
    await rig.engine.start(config: config(layouts: [desk]))
    let applying = Task { await rig.engine.applyLayout(named: "Work") }
    // A's placement lands while the hung app holds up the rest of the run.
    await rig.clock.waitForSleepers(1)
    let setup = DisplaySetup([displayA])
    let landed = await pollUntilLastKnown(rig, a.handle, setup) { $0 == leftHalfA.relative(to: v) }
    #expect(landed)
    let dragged = rect(200, 200, 300, 300)
    await rig.fake.configure { $0.windows[a.handle]?.frame = dragged }
    await rig.emit(.windowMoved(a.handle))
    await rig.waitForEvents(1)
    await rig.clock.advance(by: .milliseconds(500))
    await applying.value
    #expect(await rig.engine.memory.read().lastKnown(a.handle, setup: setup)?.relative == dragged.relative(to: v))
}

/// Polls a window's last-known frame until `matches` holds, for up to 2 s of wall-clock time.
private func pollUntilLastKnown(
    _ rig: Rig, _ window: WindowHandle, _ setup: DisplaySetup, _ matches: @Sendable (UnitRect?) -> Bool
) async -> Bool {
    let begun = ContinuousClock.now
    while await !matches(rig.engine.memory.read().lastKnown(window, setup: setup)?.relative) {
        if begun.duration(to: .now) > .seconds(2) { return false }
        await Task.yield()
    }
    return true
}

@Test(.timeLimit(.minutes(1))) func aWindowDestroyedDuringALayoutRunGetsNoLastKnownFrame() async {
    let a = window(1, frame: start, pid: 100, bundleID: "com.a")
    let slow = window(3, frame: start, pid: 50, bundleID: "com.c")
    let desk = layout("Work", [slot(.leftHalf, app: "com.a"), slot(.topHalf, app: "com.c")])
    let rig = await Rig(windows: [a, slow], focused: nil) { $0.hung = [50] }
    await rig.engine.start(config: config(layouts: [desk]))
    let applying = Task { await rig.engine.applyLayout(named: "Work") }
    await rig.waitForFrame(leftHalfA, of: a.handle)
    await rig.clock.waitForSleepers(1)
    await rig.emit(.windowDestroyed(a.handle))
    await rig.waitForEvents(1)
    await rig.clock.advance(by: .milliseconds(500))
    await applying.value
    let after = await rig.engine.memory.read()
    #expect(after.lastKnown.values.allSatisfy { $0[a.handle] == nil })
}

@Test(.timeLimit(.minutes(1))) func theStartSeedLeavesANewerMoveAlone() async {
    let onB = window(1, frame: rect(1100, 100, 400, 300))
    let rig = await Rig(displays: bothDisplays, windows: [onB], focused: nil)
    let late = FakeGate()
    await rig.fake.configure { $0.visibleWindowsLateGate = late }
    let starting = Task { await rig.engine.start(config: config()) }
    await rig.fake.waitUntil { _ in late.waiterCount == 1 }
    // The user drags the window after the seed has read it and before the seed is stored.
    let dragged = rect(1500, 600, 400, 300)
    await rig.fake.configure { $0.windows[onB.handle]?.frame = dragged }
    await rig.emit(.windowMoved(onB.handle))
    await rig.waitForEvents(1)
    late.open()
    await starting.value
    let known = await rig.engine.memory.read().lastKnown(onB.handle, setup: DisplaySetup(bothDisplays))
    #expect(known?.relative == dragged.relative(to: displayB.visibleFrame))
}

@Test(.timeLimit(.minutes(1))) func theStartSeedRecordsAReadingNewerThanAnEventsDuringIt() async {
    let onB = window(1, frame: rect(1100, 100, 400, 300))
    let rig = await Rig(displays: bothDisplays, windows: [onB], focused: nil)
    let seedRead = FakeGate()
    await rig.fake.configure { $0.visibleWindowsGate = seedRead }
    let starting = Task { await rig.engine.start(config: config()) }
    await rig.fake.waitUntil { _ in seedRead.waiterCount == 1 }
    // A move event is read and recorded while the seed waits to read; then the window moves again.
    await rig.emit(.windowMoved(onB.handle))
    await rig.waitForEvents(1)
    let moved = rect(1500, 600, 400, 300)
    await rig.fake.configure { $0.windows[onB.handle]?.frame = moved }
    seedRead.open()
    await starting.value
    let known = await rig.engine.memory.read().lastKnown(onB.handle, setup: DisplaySetup(bothDisplays))
    #expect(known?.relative == moved.relative(to: displayB.visibleFrame))
}

@Test(.timeLimit(.minutes(1))) func restartingObservationKeepsWhatAnEventLearnedMeanwhile() async {
    let rig = await Rig(windows: [window(1, frame: start)])
    await rig.engine.start(config: config())
    let gate = FakeGate()
    await rig.fake.configure { $0.startObservingGate = gate }
    let restarting = Task { await rig.engine.restartObserving() }
    await rig.fake.waitUntil { _ in gate.waiterCount == 1 }
    await rig.emit(.unobservable(pid: 300, bundleID: "com.c", missing: [.moved]))
    await rig.waitForEvents(1)
    gate.open()
    await restarting.value
    #expect(await rig.engine.unobservable == [300: [.moved]])
    await rig.waitForReport { $0 == .unobservable(bundleID: "com.c") }
}

@Test(.timeLimit(.minutes(1))) func aRulesRunStoppedAtTheSeedLeavesNoLayoutActive() async {
    let rig = await Rig(windows: [window(1, frame: start)], focused: nil)
    await rig.engine.start(config: config(layouts: [dock]))
    await rig.fake.configure { $0.displays = bothDisplays }
    let writeGate = await rig.fake.pause(beforeCall: 0)
    await rig.emit(.reconfigurationBegan)
    await rig.emit(.reconfigurationEnded)
    await rig.waitForEvents(2)
    await rig.clock.waitForSleepers(1)
    await rig.clock.advance(by: quiet)
    await rig.fake.waitUntil { _ in writeGate.waiterCount == 1 }
    // The rules' write goes through; another change begins while they seed the new setup.
    let seedReads = FakeGate()
    await rig.fake.configure { $0.visibleWindowsGate = seedReads }
    writeGate.open()
    await rig.fake.waitUntil { _ in seedReads.waiterCount == 1 }
    await rig.emit(.reconfigurationBegan)
    await rig.waitForEvents(3)
    seedReads.open()
    await rig.engine.rulesTask?.value
    #expect(await rig.engine.activeLayoutName == nil)
    #expect(await rig.engine.isFrozen)
    #expect(rig.reports.allSatisfy { if case .displayChangeHandled = $0 { false } else { true } })
    // The stopped run leaves the stored setup to the change that follows.
    #expect(await rig.engine.memory.read().lastDisplays == [displayA])

    // The change ends at the same two displays: the rules run again and the layout holds.
    await rig.emit(.reconfigurationEnded)
    await rig.waitForEvents(4)
    await rig.clock.waitForSleepers(1)
    await rig.clock.advance(by: quiet)
    await rig.waitForReport { if case .displayChangeHandled = $0 { true } else { false } }
    #expect(await rig.engine.activeLayoutName == "Dock")
    #expect(await rig.engine.isFrozen == false)
}

@Test(.timeLimit(.minutes(1))) func aReconfigurationDuringALayoutRunLeavesItInactiveAndUnreported() async {
    let desk = layout("Desk", [slot(.rightHalf)])
    let rig = await Rig(windows: [window(1, frame: start)])
    await rig.engine.start(config: config(layouts: [desk]))
    let gate = await rig.fake.pause(beforeCall: 0)
    let applying = Task { await rig.engine.applyLayout(named: "Desk") }
    await rig.fake.waitUntil { _ in gate.waiterCount == 1 }
    await rig.emit(.reconfigurationBegan)
    await rig.waitForEvents(1)
    gate.open()
    await applying.value
    #expect(await rig.engine.activeLayoutName == nil)
    await rig.fake.configure { $0.accessibilityGranted = false }
    await rig.engine.perform(.leftHalf)
    await rig.waitForReport { $0 == .failure(.permissionMissing, display: nil) }
    #expect(rig.reports.allSatisfy { if case .layoutApplied = $0 { false } else { true } })
}

// MARK: The newest operation of a kind wins

@Test(.timeLimit(.minutes(1))) func theNewestLayoutApplicationIsActiveAndSaved() async {
    let (store, directory) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let slow = window(3, frame: start, pid: 50, bundleID: "com.c")
    let other = window(2, frame: start, pid: 200, bundleID: "com.b")
    let first = layout("First", [slot(.topHalf, app: "com.c")])
    let second = layout("Second", [slot(.rightHalf, app: "com.b")])
    let rig = await Rig(windows: [slow, other], focused: nil, store: store) { $0.hung = [50] }
    await rig.engine.start(config: config(layouts: [first, second]))
    let applyingFirst = Task { await rig.engine.applyLayout(named: "First") }
    // First's run waits on the hung app while Second is applied.
    await rig.clock.waitForSleepers(1)
    await rig.engine.applyLayout(named: "Second")
    await rig.clock.advance(by: .milliseconds(500))
    await applyingFirst.value
    #expect(await rig.engine.activeLayoutName == "Second")
    guard case .loaded(let saved) = store.load() else {
        Issue.record("Expected the active layout to be saved")
        return
    }
    #expect(saved.activeLayout == "Second")
}

@Test(.timeLimit(.minutes(1))) func anOvertakenLayoutRunSendsNoMoreRequests() async {
    let slow = window(3, frame: start, pid: 50, bundleID: "com.c")
    let slowNext = window(4, frame: start, pid: 50, bundleID: "com.c")
    let other = window(2, frame: start, pid: 200, bundleID: "com.b")
    let first = layout("First", [slot(.topHalf, app: "com.c")])
    let second = layout("Second", [slot(.rightHalf, app: "com.b")])
    let rig = await Rig(windows: [slow, slowNext, other], focused: nil) { $0.hung = [50] }
    await rig.engine.start(config: config(layouts: [first, second]))
    let applyingFirst = Task { await rig.engine.applyLayout(named: "First") }
    // First's run waits on the hung app's first window while Second is applied.
    await rig.clock.waitForSleepers(1)
    await rig.engine.applyLayout(named: "Second")
    #expect(await rig.frame(of: other.handle) == rightHalfA)
    // The app answers again: First's request in flight ends, and First sends none for the next window.
    await rig.fake.configure { $0.hung = [] }
    await rig.clock.advance(by: .milliseconds(500))
    await applyingFirst.value
    let queue = await rig.engine.queue
    #expect(await queue.requestCount == 2)
    #expect(await rig.frame(of: slowNext.handle) == start)
    // First still reports what it did, and leaves the active layout to Second.
    await rig.waitForReport { $0 == .layoutApplied(name: "First", placed: 0, failed: 1) }
    #expect(await rig.engine.activeLayoutName == "Second")
}

@Test(.timeLimit(.minutes(1))) func aLayoutRunOvertakenWhileItReadsAWindowLeavesItAlone() async {
    let slow = window(3, frame: start, pid: 50, bundleID: "com.c")
    let other = window(2, frame: start, pid: 200, bundleID: "com.b")
    let first = layout("First", [slot(.topHalf, app: "com.c")])
    let second = layout("Second", [slot(.rightHalf, app: "com.b")])
    let rig = await Rig(windows: [slow, other], focused: nil)
    await rig.engine.start(config: config(layouts: [first, second]))
    // First's request has passed its check before the pipeline and is reading the window.
    let reading = await rig.fake.pauseSnapshot(at: 0)
    let applyingFirst = Task { await rig.engine.applyLayout(named: "First") }
    await rig.fake.waitUntil { _ in reading.waiterCount == 1 }
    await rig.engine.applyLayout(named: "Second")
    reading.open()
    await applyingFirst.value
    #expect(await rig.frame(of: slow.handle) == start)
    await rig.waitForReport { $0 == .layoutApplied(name: "First", placed: 0, failed: 0) }
}

@Test(.timeLimit(.minutes(1))) func aLayoutRunOvertakenWhileItsWriteWaitsOnTheQueueLeavesTheWindowAlone() async {
    let slow = window(3, frame: start, pid: 50, bundleID: "com.c")
    let other = window(2, frame: start, pid: 200, bundleID: "com.b")
    let first = layout("First", [slot(.topHalf, app: "com.c")])
    let second = layout("Second", [slot(.rightHalf, app: "com.b")])
    let rig = await Rig(windows: [slow, other], focused: nil)
    await rig.engine.start(config: config(layouts: [first, second]))
    // First's first write (call 1) waits on its app's queue, past every check made before it was queued.
    let write = await rig.fake.pause(beforeCall: 1)
    let applyingFirst = Task { await rig.engine.applyLayout(named: "First") }
    await rig.fake.waitUntil { _ in write.waiterCount == 1 }
    // Without the held write, Second's own write would take the gate and wait for it forever.
    guard write.waiterCount == 1 else { return write.open() }
    await rig.engine.applyLayout(named: "Second")
    #expect(await rig.frame(of: other.handle) == rightHalfA)
    write.open()
    await applyingFirst.value
    #expect(await rig.frame(of: slow.handle) == start)
    await rig.waitForReport { $0 == .layoutApplied(name: "First", placed: 0, failed: 0) }
    #expect(await rig.engine.activeLayoutName == "Second")
}

@Test(.timeLimit(.minutes(1))) func aReloadThatRemovesARunningLayoutKeepsItInactiveAndUnsaved() async {
    let (store, directory) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let slow = window(3, frame: start, pid: 50, bundleID: "com.c")
    let desk = layout("Desk", [slot(.topHalf, app: "com.c")])
    let rig = await Rig(windows: [slow], focused: nil, store: store) { $0.hung = [50] }
    await rig.engine.start(config: config(layouts: [desk]))
    let applying = Task { await rig.engine.applyLayout(named: "Desk") }
    // Desk's run waits on the hung app while a reload removes Desk.
    await rig.clock.waitForSleepers(1)
    await rig.engine.update(config: config())
    await rig.clock.advance(by: .milliseconds(500))
    await applying.value
    #expect(await rig.engine.activeLayoutName == nil)
    #expect(await rig.engine.memory.read().activeLayout == nil)
    #expect(store.load() == .fresh)
    // Adding Desk back does not make it active by itself.
    await rig.engine.update(config: config(layouts: [desk]))
    #expect(await rig.engine.activeLayoutName == nil)
}

@Test(.timeLimit(.minutes(1))) func aReloadThatKeepsARunningLayoutLetsItBecomeActiveAndSaved() async {
    let (store, directory) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let slow = window(3, frame: start, pid: 50, bundleID: "com.c")
    let desk = layout("Desk", [slot(.topHalf, app: "com.c")])
    let rig = await Rig(windows: [slow], focused: nil, store: store) { $0.hung = [50] }
    await rig.engine.start(config: config(layouts: [desk]))
    let applying = Task { await rig.engine.applyLayout(named: "Desk") }
    // Desk's run waits on the hung app while an unrelated change to the file is reloaded.
    await rig.clock.waitForSleepers(1)
    await rig.engine.update(config: config(gap: 10, layouts: [desk]))
    await rig.clock.advance(by: .milliseconds(500))
    await applying.value
    #expect(await rig.engine.activeLayoutName == "Desk")
    guard case .loaded(let saved) = store.load() else {
        Issue.record("Expected the active layout to be saved")
        return
    }
    #expect(saved.activeLayout == "Desk")
}

@Test(.timeLimit(.minutes(1))) func aReloadThatRemovesTheClaimingLayoutDuringTheRulesKeepsItInactive() async {
    let rig = await Rig(windows: [window(1, frame: start)], focused: nil)
    await rig.engine.start(config: config(layouts: [dock]))
    await rig.fake.configure { $0.displays = bothDisplays }
    // The dock rules' first write is held while a reload removes Dock.
    let gate = await rig.fake.pause(beforeCall: 0)
    await rig.emit(.reconfigurationBegan)
    await rig.emit(.reconfigurationEnded)
    await rig.waitForEvents(2)
    await rig.clock.waitForSleepers(1)
    await rig.clock.advance(by: quiet)
    await rig.fake.waitUntil { _ in gate.waiterCount == 1 }
    await rig.engine.update(config: config())
    gate.open()
    await rig.waitForReport { if case .displayChangeHandled = $0 { true } else { false } }
    #expect(await rig.engine.activeLayoutName == nil)
    #expect(await rig.engine.memory.read().activeLayout == nil)
    await rig.engine.update(config: config(layouts: [dock]))
    #expect(await rig.engine.activeLayoutName == nil)
}

@Test(.timeLimit(.minutes(1))) func aReloadThatKeepsTheClaimingLayoutDuringTheRulesLetsItBecomeActive() async {
    let rig = await Rig(windows: [window(1, frame: start)], focused: nil)
    await rig.engine.start(config: config(layouts: [dock]))
    await rig.fake.configure { $0.displays = bothDisplays }
    // The dock rules' first write is held while an unrelated change to the file is reloaded.
    let gate = await rig.fake.pause(beforeCall: 0)
    await rig.emit(.reconfigurationBegan)
    await rig.emit(.reconfigurationEnded)
    await rig.waitForEvents(2)
    await rig.clock.waitForSleepers(1)
    await rig.clock.advance(by: quiet)
    await rig.fake.waitUntil { _ in gate.waiterCount == 1 }
    await rig.engine.update(config: config(gap: 10, layouts: [dock]))
    gate.open()
    await rig.waitForReport { if case .displayChangeHandled = $0 { true } else { false } }
    #expect(await rig.engine.activeLayoutName == "Dock")
    #expect(await rig.engine.memory.read().activeLayout == "Dock")
}

@Test(.timeLimit(.minutes(1))) func aLayoutAppliedWhileTheRulesRunStaysActive() async {
    let other = window(2, frame: start, pid: 200, bundleID: "com.b")
    let coding = layout("Coding", [slot(.rightHalf, app: "com.b")])
    let rig = await Rig(windows: [window(1, frame: start), other], focused: nil)
    await rig.engine.start(config: config(layouts: [dock, coding]))
    await rig.fake.configure { $0.displays = bothDisplays }
    // The dock rules' first write is held, so they are still running when Coding is applied.
    let gate = await rig.fake.pause(beforeCall: 0)
    await rig.emit(.reconfigurationBegan)
    await rig.emit(.reconfigurationEnded)
    await rig.waitForEvents(2)
    await rig.clock.waitForSleepers(1)
    await rig.clock.advance(by: quiet)
    await rig.fake.waitUntil { _ in gate.waiterCount == 1 }
    await rig.engine.applyLayout(named: "Coding")
    gate.open()
    await rig.waitForReport { if case .displayChangeHandled = $0 { true } else { false } }
    #expect(await rig.engine.activeLayoutName == "Coding")
}

/// While the dock rules read the windows, Coding is applied, places the window and becomes active.
private func rulesOvertakenByALayout() async -> Rig {
    let coding = layout("Coding", [slot(.rightHalf)])
    let rig = await Rig(windows: [window(1, frame: start)], focused: nil)
    await rig.engine.start(config: config(layouts: [dock, coding]))
    let reads = FakeGate()
    await rig.fake.configure { $0.visibleWindowsGate = reads }
    await rig.changeDisplays(to: bothDisplays, eventsHandledAfter: 2)
    await rig.fake.waitUntil { _ in reads.waiterCount == 1 }
    // Without the held read, the layout's own read would take the gate and wait for it forever.
    guard reads.waiterCount == 1 else {
        reads.open()
        return rig
    }
    await rig.engine.applyLayout(named: "Coding")
    #expect(await rig.frame() == rightHalfA)
    reads.open()
    await rig.waitForChanges(1)
    return rig
}

@Test(.timeLimit(.minutes(1))) func aLayoutAppliedWhileTheRulesReadTheWindowsKeepsItsPlacements() async {
    let rig = await rulesOvertakenByALayout()
    #expect(await rig.frame() == rightHalfA)
    #expect(rig.reports.contains(.displayChangeHandled(moved: 0, failed: 0)))
    #expect(await rig.engine.activeLayoutName == "Coding")
}

@Test(.timeLimit(.minutes(1))) func anOvertakenRulesRunStillRecordsLastKnownFramesForTheNewSetup() async {
    let rig = await rulesOvertakenByALayout()
    #expect(await rig.engine.isFrozen == false)
    #expect(await rig.engine.knownDisplays == bothDisplays)
    // The seed after the run reads where Coding put the window.
    let known = await rig.engine.memory.read().lastKnown(handle, setup: DisplaySetup(bothDisplays))
    #expect(known?.relative == rightHalfA.relative(to: v))
    #expect(await rig.engine.memory.read().lastDisplays == bothDisplays)
}

@Test(.timeLimit(.minutes(1))) func aNewWindowsPlacementOvertakenByALayoutApplicationLeavesTheWindowAlone() async {
    let desk = layout("Desk", [slot(.rightHalf)])
    let coding = layout("Coding", [slot(.leftHalf, app: "com.b")])
    let other = window(2, frame: start, pid: 200, bundleID: "com.b")
    let rig = await Rig(windows: [other], focused: nil)
    await rig.engine.start(config: config(layouts: [desk, coding]))
    await rig.engine.applyLayout(named: "Desk")
    // The new window's placement, planned from Desk, is reading the window when Coding is applied.
    let created = window(1, frame: start)
    let reads = FakeGate()
    await rig.fake.configure { $0.windows[created.handle] = created; $0.snapshotGate = reads }
    await rig.emit(.windowCreated(created))
    await rig.fake.waitUntil { _ in reads.waiterCount == 1 }
    guard reads.waiterCount == 1 else { return reads.open() }
    await rig.engine.applyLayout(named: "Coding")
    #expect(await rig.frame(of: other.handle) == leftHalfA)
    reads.open()
    await rig.waitForEvents(1)
    #expect(await rig.frame() == start)
    #expect(await rig.engine.activeLayoutName == "Coding")
}

@Test(.timeLimit(.minutes(1))) func aTitlePlacementOvertakenByALayoutApplicationLeavesTheWindowAlone() async {
    let desk = layout("Desk", [slot(.rightHalf, title: "*Docs*")])
    let coding = layout("Coding", [slot(.leftHalf, app: "com.b")])
    let other = window(2, frame: start, pid: 200, bundleID: "com.b")
    let rig = await Rig(windows: [other], focused: nil)
    await rig.engine.start(config: config(layouts: [desk, coding]))
    await rig.engine.applyLayout(named: "Desk")
    let created = titled(window(1, frame: start), "Untitled")
    await rig.fake.configure { $0.windows[created.handle] = created }
    await rig.emit(.windowCreated(created))
    await rig.waitForEvents(1)
    // The title now matches Desk's entry; its placement is reading the window when Coding is applied.
    let reads = FakeGate()
    await rig.fake.configure { $0.windows[handle]?.title = "Docs"; $0.snapshotGate = reads }
    await rig.emit(.titleChanged(handle, "Docs"))
    await rig.fake.waitUntil { _ in reads.waiterCount == 1 }
    guard reads.waiterCount == 1 else { return reads.open() }
    await rig.engine.applyLayout(named: "Coding")
    #expect(await rig.frame(of: other.handle) == leftHalfA)
    reads.open()
    await rig.waitForEvents(2)
    #expect(await rig.frame() == start)
}

@Test(.timeLimit(.minutes(1))) func appsThatQuitDuringARestartAreNotMergedBack() async {
    let rig = await Rig(windows: [window(1, frame: start)])
    await rig.engine.start(config: config())
    let gate = FakeGate()
    // 400 is in the restart's answer, read before it quit.
    await rig.fake.configure {
        $0.startObservingGate = gate
        $0.unobserved = [.init(pid: 400, bundleID: "com.d", missing: [.moved])]
    }
    let restarting = Task { await rig.engine.restartObserving() }
    await rig.fake.waitUntil { _ in gate.waiterCount == 1 }
    await rig.emit(.unobservable(pid: 300, bundleID: "com.c", missing: [.moved]))
    await rig.emit(.appQuit(pid: 300))
    await rig.emit(.appQuit(pid: 400))
    await rig.waitForEvents(3)
    gate.open()
    await restarting.value
    #expect(await rig.engine.unobservable.isEmpty)
    #expect(await rig.engine.unobservableAppCount == 0)
    #expect(!rig.reports.contains(.unobservable(bundleID: "com.d")))
}

@Test(.timeLimit(.minutes(1))) func overlappingRestartsKeepWhatEventsLearned() async {
    let rig = await Rig(windows: [window(1, frame: start)])
    await rig.engine.start(config: config())
    let gate = FakeGate()
    await rig.fake.configure { $0.startObservingGate = gate }
    let first = Task { await rig.engine.restartObserving() }
    await rig.fake.waitUntil { _ in gate.waiterCount == 1 }
    let second = Task { await rig.engine.restartObserving() }
    await rig.waitForRestarts(2)
    await rig.emit(.unobservable(pid: 300, bundleID: "com.c", missing: [.moved]))
    await rig.waitForEvents(1)
    // The second restart waits for the first rather than tear down its observers.
    #expect(await rig.fake.stopObservingCount == 1)
    gate.open()
    await first.value
    await second.value
    #expect(await rig.engine.unobservable == [300: [.moved]])
}

// MARK: Stopping

@Test(.timeLimit(.minutes(1))) func stoppingDuringAReapplyDrainsTheWriteBeforeTheSave() async {
    let (store, directory) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let reapplying = EngineTiming(quietPeriod: quiet, reapplyDelay: .milliseconds(25))
    // An app that comes out 10 points narrow: a placement on another display is applied again.
    let rig = await Rig(displays: bothDisplays, windows: [window(1, frame: start)], store: store, timing: reapplying) {
        $0.sizeRule = { _, asked in ScreenSize(width: asked.width - 10, height: asked.height) }
    }
    await rig.engine.start(config: config())
    let acting = Task { await rig.engine.perform(.displayRight) }
    // The first pass has ended its session; the reapply waits on the clock.
    await rig.clock.waitForSleepers(1)
    let written = await rig.log
    #expect(written.last == "end")
    await rig.engine.stop()
    await rig.clock.advance(by: .milliseconds(25))
    await acting.value
    // No write after stop, and the save holds where the first pass left the window.
    #expect(await rig.log == written)
    guard case .loaded(let saved) = store.load() else {
        Issue.record("Expected stop to save the memory")
        return
    }
    #expect(saved.placed[handle]?.display == displayB.identity)
    #expect(rig.reports == [.memory(.fresh)])
}

@Test(.timeLimit(.minutes(1))) func aRequestAfterStopBeganIsRefused() async {
    let other = window(2, frame: start, pid: 200, bundleID: "com.b")
    let desk = layout("Desk", [slot(.rightHalf, app: "com.b")])
    let rig = await Rig(windows: [window(1, frame: start), other])
    await rig.engine.start(config: config(layouts: [desk]))
    // The first write is held, so stop is still waiting for it when the next requests come.
    let gate = await rig.fake.pause(beforeCall: 1)
    let acting = Task { await rig.engine.perform(.leftHalf) }
    await rig.fake.waitUntil { _ in gate.waiterCount == 1 }
    let stopping = Task { await rig.engine.stop() }
    await rig.waitUntilStopping()
    await rig.fake.configure { $0.focused = other.handle }
    await rig.engine.perform(.rightHalf)
    await rig.engine.applyLayout(named: "Desk")
    gate.open()
    await acting.value
    await stopping.value
    #expect(await rig.frame(of: other.handle) == start)
    #expect(await rig.log.filter { $0 == "begin" }.count == 1)
    #expect(rig.reports == [.memory(.fresh)])
}

/// Quit while startup's rules are still reading the windows: placing stops at once, before startup is
/// awaited, so the run sends nothing once the read returns, and the memory is saved when `stop` finishes.
@Test(.timeLimit(.minutes(1))) func aStopBeginningWhileStartupsRulesAwaitTheWindowsMovesNothingAfterIt() async {
    let (store, directory) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = await Rig(displays: bothDisplays, windows: [window(1, frame: rect(1100, 100, 400, 300))], store: store)
    await first.engine.start(config: config())
    await first.engine.perform(.firstThird)
    await first.emit(.windowMoved(handle))
    await first.waitForEvents(1)
    await first.engine.stop()

    // Next launch: B is gone, and the rules would move the window. Quit comes while they read the windows.
    let moved = rect(300, 300, 400, 300)
    let second = await Rig(windows: [window(1, frame: moved)], store: store)
    let reads = FakeGate()
    await second.fake.configure { $0.visibleWindowsGate = reads }
    let starting = Task { await second.engine.start(config: config()) }
    await second.fake.waitUntil { _ in reads.waiterCount == 1 }
    await second.engine.stopPlacing()
    reads.open()
    await starting.value
    #expect(await second.log.isEmpty)
    #expect(await second.frame() == moved)

    // The memory is saved once startup has ended, and the setup it holds is still the old one.
    try? FileManager.default.removeItem(at: directory)
    await second.engine.stop()
    guard case .loaded(let saved) = store.load() else {
        Issue.record("Expected stop to save the memory")
        return
    }
    #expect(saved.lastDisplays == bothDisplays)
    #expect(second.reports.allSatisfy { if case .displayChangeHandled = $0 { false } else { true } })
}

/// Quit while startup's rules wait on an app's write: the app's next request is stopped only by the
/// halted queue, since startup's own checks (the count of reconfigurations, the layout application) do
/// not change when a stop begins.
@Test(.timeLimit(.minutes(1))) func aStopBeginningWhileStartupsRulesAwaitAWriteStartsNoLaterRequest() async {
    let (store, directory) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = await Rig(displays: bothDisplays, windows: [strayB1, strayB2], focused: nil, store: store)
    await first.engine.start(config: config())
    await first.engine.stop()

    // Next launch: B is gone, and the rules would move both windows, one app's, one after the other.
    let one = rect(50, 50, 300, 300)
    let two = rect(400, 400, 300, 300)
    let second = await Rig(
        windows: [window(1, frame: one), window(2, frame: two)], focused: nil, store: store
    )
    let write = await second.fake.pause(beforeCall: 0)
    let starting = Task { await second.engine.start(config: config()) }
    await second.fake.waitUntil { _ in write.waiterCount == 1 }
    await second.engine.stopPlacing()
    write.open()
    await starting.value
    #expect(await second.log.filter { $0 == "begin" }.count == 1)
    #expect(await second.log.filter { $0.hasPrefix("size") || $0.hasPrefix("position") }.allSatisfy { $0.hasSuffix("cancelled") })
    #expect(await second.frame(of: strayB1.handle) == one)
    #expect(await second.frame(of: strayB2.handle) == two)
    #expect(second.reports.allSatisfy { if case .displayChangeHandled = $0 { false } else { true } })
    await second.engine.stop()
}

/// Quit while a layout run waits on a slow app's write: the held write ends cancelled, and the run's
/// other window is not written.
@Test(.timeLimit(.minutes(1))) func aStopBeginningWhileALayoutRunWaitsOnASlowAppWritesNothingAfterIt() async {
    let (store, directory) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let one = window(1, frame: start)
    let two = window(2, frame: start)
    let desk = layout("Desk", [slot(.rightHalf)])
    let rig = await Rig(windows: [one, two], focused: nil, store: store)
    await rig.engine.start(config: config(layouts: [desk]))
    // The app's first write is held, as a slow app holds it.
    let gate = await rig.fake.pause(beforeCall: 1)
    let applying = Task { await rig.engine.applyLayout(named: "Desk") }
    await rig.fake.waitUntil { _ in gate.waiterCount == 1 }
    await rig.engine.stopPlacing()
    gate.open()
    await applying.value
    #expect(await rig.log.filter { $0.hasPrefix("size") || $0.hasPrefix("position") }.allSatisfy { $0.hasSuffix("cancelled") })
    #expect(await rig.frame(of: one.handle) == start)
    #expect(await rig.frame(of: two.handle) == start)
    #expect(rig.reports == [.memory(.fresh)])

    await rig.engine.stop()
    guard case .loaded = store.load() else {
        Issue.record("Expected stop to save the memory")
        return
    }
}

// MARK: Windows that stop being placeable

@Test(.timeLimit(.minutes(1))) func aWindowMinimisedWhileALayoutRunsIsSkipped() async {
    let first = window(1, frame: start)
    let second = window(2, frame: rect(150, 150, 400, 300))
    let desk = layout("Desk", [slot(.rightHalf)])
    let rig = await Rig(windows: [first, second], focused: nil)
    await rig.engine.start(config: config(layouts: [desk]))
    // The run waits on the first window's first write while the user minimises the second.
    let gate = await rig.fake.pause(beforeCall: 1)
    let applying = Task { await rig.engine.applyLayout(named: "Desk") }
    await rig.fake.waitUntil { _ in gate.waiterCount == 1 }
    await rig.fake.configure { $0.windows[second.handle]?.isMinimized = true }
    gate.open()
    await applying.value
    #expect(await rig.frame(of: second.handle) == second.frame)
    #expect(await rig.log.filter { $0 == "begin" }.count == 1)
    #expect(rig.reports == [.memory(.fresh), .layoutApplied(name: "Desk", placed: 1, failed: 0)])
    #expect(await rig.engine.memory.read().placed[second.handle] == nil)
}

@Test(.timeLimit(.minutes(1))) func aWindowOfAnAppHiddenWhileTheRulesRunIsSkipped() async {
    let rig = await Rig(displays: bothDisplays, windows: [strayB1, strayB2], focused: nil)
    await rig.engine.start(config: config())
    await rig.fake.configure {
        $0.displays = [displayA]
        $0.windows[strayB1.handle]?.frame = rect(50, 50, 300, 300)
        $0.windows[strayB2.handle]?.frame = rect(400, 400, 300, 300)
    }
    // The rules wait on the first window's first write while the user hides the app's second window.
    let gate = await rig.fake.pause(beforeCall: 0)
    await rig.emit(.reconfigurationBegan)
    await rig.emit(.reconfigurationEnded)
    await rig.waitForEvents(2)
    await rig.clock.waitForSleepers(1)
    await rig.clock.advance(by: quiet)
    await rig.fake.waitUntil { _ in gate.waiterCount == 1 }
    await rig.fake.configure { $0.windows[strayB2.handle]?.isAppHidden = true }
    gate.open()
    await rig.waitForReport { $0 == .displayChangeHandled(moved: 1, failed: 0) }
    #expect(await rig.frame(of: strayB2.handle) == rect(400, 400, 300, 300))
    #expect(rig.reports.allSatisfy { if case .failure = $0 { false } else { true } })
}

// MARK: Memory of gone windows

/// How many write-session calls the placement makes, from a rig that runs it undisturbed.
private func callsOf(_ placement: @Sendable (Rig) async -> Void, config: Config) async -> Int {
    let reference = await Rig(windows: [window(1, frame: start)], focused: handle)
    await reference.engine.start(config: config)
    await placement(reference)
    return await reference.log.count
}

@Test(.timeLimit(.minutes(1))) func aWindowDestroyedWhileAnActionEndsItsSessionGetsNoMemory() async {
    let calls = await callsOf({ await $0.engine.perform(.leftHalf) }, config: config())
    let rig = await Rig(windows: [window(1, frame: start)])
    await rig.engine.start(config: config())
    // The session's end is held, as while Enhanced UI is restored, and the window is destroyed.
    let ending = await rig.fake.pause(beforeCall: calls - 1)
    let acting = Task { await rig.engine.perform(.leftHalf) }
    await rig.fake.waitUntil { _ in ending.waiterCount == 1 }
    await rig.emit(.windowDestroyed(handle))
    await rig.waitForEvents(1)
    ending.open()
    await acting.value
    let memory = await rig.engine.memory.read()
    #expect(memory.placed[handle] == nil)
    #expect(memory.restore[handle] == nil)
    #expect(memory.lastKnown.values.allSatisfy { $0[handle] == nil })
}

@Test(.timeLimit(.minutes(1))) func aWindowDestroyedWhileALayoutRunEndsItsSessionGetsNoMemory() async {
    let desk = layout("Desk", [slot(.rightHalf)])
    let calls = await callsOf({ await $0.engine.applyLayout(named: "Desk") }, config: config(layouts: [desk]))
    let rig = await Rig(windows: [window(1, frame: start)], focused: nil)
    await rig.engine.start(config: config(layouts: [desk]))
    let ending = await rig.fake.pause(beforeCall: calls - 1)
    let applying = Task { await rig.engine.applyLayout(named: "Desk") }
    await rig.fake.waitUntil { _ in ending.waiterCount == 1 }
    await rig.emit(.windowDestroyed(handle))
    await rig.waitForEvents(1)
    ending.open()
    await applying.value
    let memory = await rig.engine.memory.read()
    #expect(memory.placed[handle] == nil)
    #expect(memory.restore[handle] == nil)
    #expect(memory.lastKnown.values.allSatisfy { $0[handle] == nil })
}

// MARK: Held frames on every exit

@Test(.timeLimit(.minutes(1))) func aDragHeldWhileAFailedWriteEndsClosesTheChain() async {
    let rig = await Rig(displays: bothDisplays, windows: [window(1, frame: start)])
    await rig.engine.start(config: config())
    // Across displays the size goes first: begin 0, size 1, read 2, position 3, end 4.
    // The position write fails; the session's end is held while the user drags the window.
    let ending = await rig.fake.pause(beforeCall: 4)
    await rig.fake.configure { $0.beforeCall = [3: { $0.canMove = false }] }
    let acting = Task { await rig.engine.perform(.displayRight) }
    await rig.fake.waitUntil { _ in ending.waiterCount == 1 }
    #expect(await rig.log == ["begin", "size 800x600", "read", "position 1200,150"])
    await rig.fake.configure { $0.windows[handle]?.frame = rect(300, 300, 400, 300) }
    await rig.emit(.windowMoved(handle))
    await rig.waitForEvents(1)
    ending.open()
    await acting.value
    let memory = await rig.engine.memory.read()
    #expect(memory.restore[handle]?.chainOpen == false)
    await rig.waitForReport { if case .failure = $0 { true } else { false } }
    #expect(rig.reports.contains { if case .failure(.movedDuringPlacement, _) = $0 { true } else { false } })
}

// MARK: Readings in read order

@Test(.timeLimit(.minutes(1))) func aFrameFromBeforeAChangeThatIsNotRecordedLeavesTheSeedsFrame() async {
    let rig = await Rig(displays: bothDisplays, windows: [strayB1], focused: nil)
    await rig.engine.start(config: config())
    // A move event arrives before the change; its read waits until the rules' seed has read.
    let eventRead = FakeGate()
    await rig.fake.configure { $0.snapshotGate = eventRead }
    await rig.emit(.windowMoved(strayB1.handle))
    await rig.fake.waitUntil { _ in eventRead.waiterCount == 1 }
    // Undock; the rules' first write is held while B comes back.
    let writing = await rig.fake.pause(beforeCall: 0)
    await rig.fake.configure { $0.displays = [displayA]; $0.windows[strayB1.handle]?.frame = rect(50, 50, 300, 300) }
    await rig.emit(.reconfigurationBegan)
    await rig.emit(.reconfigurationEnded)
    await rig.waitForEvents(2)
    await rig.clock.waitForSleepers(1)
    await rig.clock.advance(by: quiet)
    await rig.fake.waitUntil { _ in writing.waiterCount == 1 }
    // B comes back. The window can no longer be moved, so the rules run again on the setup the
    // event belongs to and leave the window where it is; their seed reads it and waits.
    await rig.fake.configure { $0.displays = bothDisplays; $0.windows[strayB1.handle]?.canMove = false }
    let seedRead = await rig.fake.pauseVisibleWindowsResult(at: 3)
    await rig.emit(.reconfigurationBegan)
    await rig.emit(.reconfigurationEnded)
    await rig.waitForEvents(4)
    writing.open()
    await rig.clock.waitForSleepers(1)
    await rig.clock.advance(by: quiet)
    await rig.fake.waitUntil { _ in seedRead.waiterCount == 1 }
    // The event reads the window after the seed did; its context is from before the change.
    eventRead.open()
    await rig.waitForEvents(5)
    seedRead.open()
    await rig.waitForChanges(1)
    let known = await rig.engine.memory.read().lastKnown(strayB1.handle, setup: DisplaySetup(bothDisplays))
    #expect(known?.display == displayA.identity)
    #expect(known?.relative == rect(50, 50, 300, 300).relative(to: v))
}

@Test(.timeLimit(.minutes(1))) func aFrameReadBeforeANewWindowsPlacementIsNotATouch() async {
    let desk = layout("Desk", [slot(.rightHalf, title: "*Docs*"), slot(.leftHalf)])
    let rig = await Rig(focused: nil)
    await rig.engine.start(config: config(layouts: [desk]))
    await rig.engine.applyLayout(named: "Desk")
    let created = titled(window(1, frame: start), "Untitled")
    let placing = FakeGate()
    await rig.fake.configure { $0.windows[created.handle] = created; $0.snapshotGate = placing }
    await rig.emit(.windowCreated(created))
    await rig.fake.waitUntil { _ in placing.waiterCount == 1 }
    // A move event reads the window where the app opened it, before the placement reads it; the
    // answer arrives once the placement has landed.
    let late = FakeGate()
    await rig.fake.configure { $0.snapshotLateGate = late }
    await rig.emit(.windowMoved(handle))
    await rig.fake.waitUntil { _ in late.waiterCount == 1 }
    placing.open()
    let setup = DisplaySetup([displayA])
    #expect(await pollUntilLastKnown(rig, handle, setup) { $0 == leftHalfA.relative(to: v) })
    late.open()
    await rig.waitForEvents(2)
    #expect(await !rig.isTouched())
    #expect(await rig.engine.memory.read().lastKnown(handle, setup: setup)?.relative == leftHalfA.relative(to: v))

    // The title that matches comes within the second, and the user has not touched the window.
    await rig.fake.configure { $0.windows[handle]?.title = "Docs" }
    await rig.emit(.titleChanged(handle, "Docs"))
    await rig.waitForFrame(rightHalfA)
}

// MARK: From Resolve's read

@Test(.timeLimit(.minutes(1))) func aFrameReadJustBeforeANewWindowsPlacementReadsItIsNotATouch() async {
    let desk = layout("Desk", [slot(.rightHalf)])
    let rig = await Rig(focused: nil)
    await rig.engine.start(config: config(layouts: [desk]))
    await rig.engine.applyLayout(named: "Desk")
    let created = window(1, frame: start)
    let placing = FakeGate()
    await rig.fake.configure { $0.windows[created.handle] = created; $0.snapshotGate = placing }
    await rig.emit(.windowCreated(created))
    await rig.fake.waitUntil { _ in placing.waiterCount == 1 }
    // A move event reads the window where the app opened it, just before the placement reads it.
    let late = FakeGate()
    await rig.fake.configure { $0.snapshotLateGate = late }
    await rig.emit(.windowMoved(handle))
    await rig.fake.waitUntil { _ in late.waiterCount == 1 }
    // The placement reads the window, then waits at Resolve's next call; the event is judged there.
    let resolving = FakeGate()
    await rig.fake.configure { $0.displaysGate = resolving }
    placing.open()
    await rig.fake.waitUntil { _ in resolving.waiterCount == 1 }
    late.open()
    await rig.waitForEvents(1)
    #expect(await !rig.isTouched())
    resolving.open()
    await rig.waitForFrame(rightHalfA)
}

@Test(.timeLimit(.minutes(1))) func aMoveBetweenResolveAndTheFirstWriteStopsTheAction() async {
    let rig = await Rig(windows: [window(1, frame: start)])
    await rig.engine.start(config: config())
    let resolving = FakeGate()
    await rig.fake.configure { $0.displaysGate = resolving }
    let acting = Task { await rig.engine.perform(.leftHalf) }
    await rig.fake.waitUntil { _ in resolving.waiterCount == 1 }
    // Resolve has read the window; the user drags it before the first write.
    let dragged = rect(300, 300, 400, 300)
    await rig.fake.configure { $0.windows[handle]?.frame = dragged }
    await rig.emit(.windowMoved(handle))
    await rig.waitForEvents(1)
    resolving.open()
    await acting.value
    #expect(await rig.frame() == dragged)
    // Interrupted before Apply began: no session was opened.
    #expect(await rig.log == [])
    await rig.waitForReport { $0 == .failure(.movedDuringPlacement, display: displayA.identity) }
    #expect(await rig.engine.memory.read().restore[handle]?.chainOpen != true)
}

@Test(.timeLimit(.minutes(1))) func aNewWindowMovedBeforeItsPlacementReadsItStaysWhereItWasMoved() async {
    let desk = layout("Desk", [slot(.rightHalf)])
    let rig = await Rig(focused: nil)
    await rig.engine.start(config: config(layouts: [desk]))
    await rig.engine.applyLayout(named: "Desk")
    let created = window(1, frame: start)
    let placing = FakeGate()
    await rig.fake.configure { $0.windows[created.handle] = created; $0.snapshotGate = placing }
    await rig.emit(.windowCreated(created))
    await rig.fake.waitUntil { _ in placing.waiterCount == 1 }
    // The user moves the new window. Its event reads the new frame first, but is judged last: the
    // placement's own read is the first Tafl accepts of the moved window.
    let dragged = rect(300, 300, 400, 300)
    let late = FakeGate()
    await rig.fake.configure { $0.windows[handle]?.frame = dragged; $0.snapshotLateGate = late }
    await rig.emit(.windowMoved(handle))
    await rig.fake.waitUntil { _ in late.waiterCount == 1 }
    placing.open()
    await rig.waitForEvents(1)
    late.open()
    await rig.waitForEvents(2)
    #expect(await rig.frame() == dragged)
    // The placement declined the touched window before Apply opened a session.
    #expect(await rig.log == [])
    #expect(await rig.isTouched())
}

// MARK: One owner per window: cases 1-6

private let dragged = rect(300, 300, 400, 300)

/// The user drags a window Tafl placed, then an action runs; Resolve reads the dragged frame. With
/// `eventReadFirst`, the drag's own notification reads the window after the action's reads and its
/// result is held until Resolve has its reading; otherwise it reads while Resolve waits for the
/// displays.
private func dragThenAct(eventReadFirst: Bool) async -> (Rig, RestoreRecord?) {
    let rig = await Rig(windows: [window(1, frame: start)])
    await rig.engine.start(config: config())
    await rig.engine.perform(.leftHalf)
    await rig.fake.configure { $0.windows[handle]?.frame = dragged }
    let acting: Task<Void, Never>
    if eventReadFirst {
        // The action reads the focused window first; Resolve's read is the call after it.
        let next = await rig.fake.snapshotCount
        let resolveRead = await rig.fake.pauseSnapshot(at: next + 1)
        acting = Task { await rig.engine.perform(.rightHalf) }
        await rig.fake.waitUntil { _ in resolveRead.waiterCount == 1 }
        let late = FakeGate()
        await rig.fake.configure { $0.snapshotLateGate = late }
        resolveRead.open()
        await rig.fake.waitUntil { _ in late.waiterCount == 1 }
        await rig.emit(.windowMoved(handle))
        await rig.waitForEvents(1)
        late.open()
    } else {
        let resolving = FakeGate()
        await rig.fake.configure { $0.displaysGate = resolving }
        acting = Task { await rig.engine.perform(.rightHalf) }
        await rig.fake.waitUntil { _ in resolving.waiterCount == 1 }
        await rig.emit(.windowMoved(handle))
        await rig.waitForEvents(1)
        resolving.open()
    }
    await acting.value
    return (rig, await rig.engine.memory.read().restore[handle])
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func anActionAfterADragStartsANewChainAtTheDraggedFrame(eventReadFirst: Bool) async {
    let (rig, restore) = await dragThenAct(eventReadFirst: eventReadFirst)
    #expect(await rig.frame() == rightHalfA)
    #expect(restore?.frame == dragged)
    #expect(restore?.chainOpen == true)
    await rig.engine.perform(.restore)
    #expect(await rig.frame() == dragged)
}

/// Resolve's read is the first Tafl has of the drag: the action's focused read came before it, and
/// the window moves while Resolve's read waits. The drag is no interruption of a request not yet begun.
@Test(.timeLimit(.minutes(1))) func anActionWhoseResolveReadFirstSeesADragStartsANewChainThere() async {
    let rig = await Rig(windows: [window(1, frame: start)])
    await rig.engine.start(config: config())
    await rig.engine.perform(.leftHalf)
    // The action reads the focused window first; Resolve's read is the call after it.
    let next = await rig.fake.snapshotCount
    let resolveRead = await rig.fake.pauseSnapshot(at: next + 1)
    let acting = Task { await rig.engine.perform(.rightHalf) }
    await rig.fake.waitUntil { _ in resolveRead.waiterCount == 1 }
    await rig.fake.configure { $0.windows[handle]?.frame = dragged }
    resolveRead.open()
    await acting.value
    #expect(await rig.frame() == rightHalfA)
    #expect(await rig.engine.memory.read().restore[handle] == RestoreRecord(
        frame: dragged, display: displayA.identity, visibleFrame: v, chainOpen: true
    ))
    // The drag's own notification reads the window after the action: Tafl's own frame by then.
    await rig.emit(.windowMoved(handle))
    await rig.waitForEvents(1)
    #expect(rig.reports.allSatisfy { if case .failure = $0 { false } else { true } })
    await rig.engine.perform(.restore)
    #expect(await rig.frame() == dragged)
}

/// A new window the user moves while its placement waits to read it. With `eventReadFirst`, the
/// move's read is done before the placement reads; otherwise its result is held until then.
@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func aNewWindowMovedBeforeItsPlacementReadsItKeepsTheMovedFrame(eventReadFirst: Bool) async {
    let desk = layout("Desk", [slot(.rightHalf)])
    let rig = await Rig(focused: nil)
    await rig.engine.start(config: config(layouts: [desk]))
    await rig.engine.applyLayout(named: "Desk")
    let created = window(1, frame: start)
    let placing = FakeGate()
    await rig.fake.configure { $0.windows[created.handle] = created; $0.snapshotGate = placing }
    await rig.emit(.windowCreated(created))
    await rig.fake.waitUntil { _ in placing.waiterCount == 1 }
    if eventReadFirst {
        await rig.fake.configure { $0.windows[handle]?.frame = dragged }
        await rig.emit(.windowMoved(handle))
        await rig.waitForEvents(1)
        placing.open()
        await rig.waitForEvents(2)
    } else {
        let late = FakeGate()
        await rig.fake.configure { $0.windows[handle]?.frame = dragged; $0.snapshotLateGate = late }
        await rig.emit(.windowMoved(handle))
        await rig.fake.waitUntil { _ in late.waiterCount == 1 }
        placing.open()
        await rig.waitForEvents(1)
        late.open()
        await rig.waitForEvents(2)
    }
    #expect(await rig.frame() == dragged)
    #expect(await rig.isTouched())
    let known = await rig.engine.memory.read().lastKnown(handle, setup: DisplaySetup([displayA]))
    #expect(known?.relative == dragged.relative(to: v))
}

/// A new window the user moves while its placement waits to read it, the placement's read judged
/// before the move's own: the move's read is held until the placement has read the moved window.
@Test(.timeLimit(.minutes(1))) func aNewWindowMovedWhoseMoveEventReadsAfterItsPlacementKeepsTheMovedFrame() async {
    let desk = layout("Desk", [slot(.rightHalf)])
    let rig = await Rig(focused: nil)
    await rig.engine.start(config: config(layouts: [desk]))
    await rig.engine.applyLayout(named: "Desk")
    let created = window(1, frame: start)
    let placing = FakeGate()
    await rig.fake.configure { $0.windows[created.handle] = created; $0.snapshotGate = placing }
    await rig.emit(.windowCreated(created))
    await rig.fake.waitUntil { _ in placing.waiterCount == 1 }
    // The move's notification waits before it reads, behind the placement.
    let eventRead = FakeGate()
    await rig.fake.configure { $0.windows[handle]?.frame = dragged; $0.snapshotGate = eventRead }
    await rig.emit(.windowMoved(handle))
    await rig.fake.waitUntil { _ in eventRead.waiterCount == 1 }
    placing.open()
    await rig.waitForEvents(1)
    #expect(await rig.isTouched())
    eventRead.open()
    await rig.waitForEvents(2)
    #expect(await rig.frame() == dragged)
    let known = await rig.engine.memory.read().lastKnown(handle, setup: DisplaySetup([displayA]))
    #expect(known?.relative == dragged.relative(to: v))
}

@Test(.timeLimit(.minutes(1))) func aDragAfterAWriteFailedMidwayIsAnExternalChange() async {
    let rig = await Rig(displays: bothDisplays, windows: [window(1, frame: start)])
    await rig.engine.start(config: config())
    // Across displays the size goes first: begin 0, size 1, read 2, position 3, end 4. The position fails.
    await rig.fake.configure { $0.beforeCall = [3: { $0.canMove = false }] }
    await rig.engine.perform(.displayRight)
    #expect(await rig.log == ["begin", "size 800x600", "read", "position 1200,150", "end"])
    #expect(await rig.engine.memory.read().restore[handle]?.chainOpen == true)
    await rig.fake.configure { $0.windows[handle]?.frame = dragged }
    await rig.emit(.windowMoved(handle))
    await rig.waitForEvents(1)
    #expect(await rig.engine.memory.read().restore[handle]?.chainOpen == false)
    #expect(await rig.isTouched())
}

@Test(.timeLimit(.minutes(1))) func aNewWindowWithADestroyedWindowsIDStartsFresh() async {
    let rig = await Rig(windows: [window(1, frame: start)])
    await rig.engine.start(config: config())
    await rig.engine.perform(.leftHalf)
    await rig.fake.configure { $0.windows[handle] = nil }
    await rig.emit(.windowDestroyed(handle))
    await rig.waitForEvents(1)
    #expect(await rig.engine.memory.read().placed[handle] == nil)
    // A new window gets the destroyed one's id.
    await rig.fake.configure { $0.windows[handle] = window(1, frame: start) }
    await rig.engine.perform(.rightHalf)
    #expect(await rig.frame() == rightHalfA)
    let memory = await rig.engine.memory.read()
    #expect(memory.placed[handle]?.action == .rightHalf)
    #expect(memory.restore[handle]?.frame == start)
    #expect(memory.lastKnown(handle, setup: DisplaySetup([displayA]))?.relative == rightHalfA.relative(to: v))
}

@Test(.timeLimit(.minutes(1))) func aFirstNotificationAtTheSeededFrameKeepsAPlacedRecordFromDisk() async throws {
    var saved = WindowMemory(lastDisplays: bothDisplays, savedAt: saveDate)
    saved.openChain(handle, before: start, on: displayA)
    saved.recordPlaced(handle, PlacedRecord(
        action: .leftHalf, layout: nil, placement: .leftHalf, cycleStep: 0, achieved: leftHalfA, display: displayA.identity
    ))
    let (store, directory) = try storeHolding(saved)
    defer { try? FileManager.default.removeItem(at: directory) }
    let rig = await Rig(displays: bothDisplays, windows: [window(1, frame: leftHalfA)], store: store) {
        $0.launched = [100: saveDate.addingTimeInterval(-60)]
    }
    await rig.engine.start(config: config())
    await rig.emit(.windowMoved(handle))
    await rig.waitForEvents(1)
    #expect(await rig.engine.memory.read().placed[handle]?.achieved == leftHalfA)
    // Still placed by left-half, so pressing it again is a repeat: the right half of the other display.
    await rig.engine.perform(.leftHalf)
    #expect(await rig.frame() == rect(2000, 0, 1000, 1550))
}
