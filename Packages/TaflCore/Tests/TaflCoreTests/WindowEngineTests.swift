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

@Test func hungAppDoesNotBlockOthers() async {
    let a = window(1, frame: start, pid: 100, bundleID: "com.a")
    let b = window(2, frame: start, pid: 200, bundleID: "com.b")
    let c = window(3, frame: start, pid: 300, bundleID: "com.c")
    let desk = layout("Work", [slot(.leftHalf, app: "com.a"), slot(.rightHalf, app: "com.b"), slot(.topHalf, app: "com.c")])
    let elsewhere = window(4, frame: start, pid: 400, bundleID: "com.d")
    let rig = await Rig(windows: [a, b, c, elsewhere], focused: elsewhere.handle) { $0.hung = [300] }
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
    await rig.waitForReport { $0 == .layoutApplied(name: "Work", placed: 2, failed: 1) }
    #expect(rig.reports == [.memory(.fresh), .layoutApplied(name: "Work", placed: 2, failed: 1)])
    #expect(await rig.engine.activeLayoutName == "Work")
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
    await rig.waitForReport { $0 == .displayChangeHandled(moved: 1) }
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
    await rig.waitForReport { $0 == .displayChangeHandled(moved: 1) }
    #expect(await rig.frame() == leftHalfA)
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
    await rig.waitForReport { $0 == .displayChangeHandled(moved: 1) }
    #expect(await rig.frame() == leftHalfA)
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
    await rig.waitForReport { $0 == .displayChangeHandled(moved: 1) }
    #expect(await rig.frame(of: observed.handle) == leftHalfA)
    #expect(await rig.frame(of: unobserved.handle) == asleep)
    #expect(rig.reports.filter { $0 == .unobservable(bundleID: "com.b") }.count == 1)
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
    await second.waitForReport { $0 == .displayChangeHandled(moved: 1) }
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
