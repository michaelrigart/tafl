import Synchronization
import Testing
import TaflTestSupport
@testable import TaflCore

private func makeFake(_ windows: WindowSnapshot...) async -> (FakePlatform, ManualClock) {
    let clock = ManualClock()
    let fake = FakePlatform(clock: clock, displays: [displayA, displayB])
    await fake.configure { fake in
        for window in windows { fake.windows[window.handle] = window }
    }
    return (fake, clock)
}

private func session(_ fake: FakePlatform, _ handle: WindowHandle) async throws -> any WriteSession {
    try await fake.beginWriting(handle).get()
}

private let admitted: @Sendable () -> WriteGo = { .write }

@Test func fakeRecordsCallsAndAppliesRules() async throws {
    let w = window(1, frame: rect(10, 10, 400, 300))
    let (fake, _) = await makeFake(w)
    let s = try await session(fake, w.handle)
    #expect(try await s.setSize(ScreenSize(width: 500, height: 775), admit: admitted).get() == .write)
    #expect(try await s.setPosition(ScreenPoint(x: 0, y: 25), admit: admitted).get() == .write)
    #expect(try await s.readFrame(take: { $0 }).get() == rect(0, 25, 500, 775))
    #expect(await fake.callLog == ["begin", "size 500x775", "position 0,25", "read"])

    await fake.configure { $0.sizeRule = { _, asked in ScreenSize(width: min(asked.width, 600), height: asked.height) } }
    #expect(try await s.setSize(ScreenSize(width: 800, height: 775), admit: admitted).get() == .write)
    #expect(try await s.readFrame(take: { $0 }).get().width == 600)

    await s.end()
    #expect(await fake.callLog.last == "end")
}

private final class Taken: Sendable {
    private let frames = Mutex<[ScreenRect]>([])
    func add(_ frame: ScreenRect) { frames.withLock { $0.append(frame) } }
    var all: [ScreenRect] { frames.withLock { $0 } }
}

@Test(.gated, .timeLimit(.minutes(1))) func aReadHandsWhatItReadToTakeBeforeItsResultIsHeld() async {
    let w = window(1, frame: rect(10, 10, 400, 300))
    let (fake, _) = await makeFake(w)
    let taken = Taken()
    let late = Gate()
    await fake.configure { $0.snapshotLateGate = late }
    let read = Task {
        await fake.snapshot(of: w.handle) { snapshot in
            taken.add(snapshot.frame)
            return snapshot.frame
        }
    }
    await late.waitUntilHolding(1)
    #expect(taken.all == [w.frame])

    let listedLate = Gate()
    await fake.configure { $0.visibleWindowsLateGate = listedLate }
    let listing = Task { await fake.visibleWindows { taken.add($0.frame) } }
    await listedLate.waitUntilHolding(1)
    #expect(taken.all == [w.frame, w.frame])
    late.open()
    listedLate.open()
    #expect(await read.bounded() == .success(w.frame))
    #expect(await listing.bounded()?.count == 1)
}

@Test func fakeLogsFractionalNumbersWithTheirDecimals() async throws {
    let w = window(1, frame: rect(0, 0, 100, 100))
    let (fake, _) = await makeFake(w)
    let s = try await session(fake, w.handle)
    #expect(try await s.setSize(ScreenSize(width: 500.5, height: 775), admit: admitted).get() == .write)
    #expect(await fake.callLog == ["begin", "size 500.5x775"])
}

@Test func endIsIdempotent() async throws {
    let w = window(1, frame: rect(0, 0, 100, 100))
    let (fake, _) = await makeFake(w)
    let s = try await session(fake, w.handle)
    await s.end()
    await s.end()
    #expect(await fake.callLog == ["begin", "end"])
    // The slot is free again, so this returns instead of waiting behind a stale session.
    _ = try await session(fake, w.handle)
}

@Test func sessionsForOneAppSerialize() async throws {
    let a = window(1, frame: rect(0, 0, 100, 100), pid: 100)
    let b = window(2, frame: rect(0, 0, 100, 100), pid: 100)
    let other = window(3, frame: rect(0, 0, 100, 100), pid: 200)
    let (fake, _) = await makeFake(a, b, other)
    let first = try await session(fake, a.handle)

    let secondReturned = Mutex(false)
    let second = Task {
        let result = await fake.beginWriting(b.handle)
        secondReturned.withLock { $0 = true }
        return result
    }
    let otherApp = try await session(fake, other.handle)
    await waitUntil("the second session to wait for the first") { await fake.waitingSessionCount == 1 }
    #expect(secondReturned.withLock { $0 } == false)
    #expect(await fake.callLog == ["begin", "begin"])

    await first.end()
    guard let secondResult = await second.bounded() else { return }
    let secondSession = try secondResult.get()
    #expect(secondReturned.withLock { $0 })
    #expect(await fake.callLog == ["begin", "begin", "end", "begin"])
    await secondSession.end()
    await otherApp.end()
}

@Test func beforeCallInjectsExternalChange() async throws {
    let w = window(1, frame: rect(0, 0, 100, 100))
    let (fake, _) = await makeFake(w)
    await fake.configure { $0.beforeCall[1] = { $0.frame.origin = ScreenPoint(x: 300, y: 300) } }
    let s = try await session(fake, w.handle)
    #expect(try await s.setSize(ScreenSize(width: 500, height: 400), admit: admitted).get() == .write)
    #expect(try await s.readFrame(take: { $0 }).get() == rect(300, 300, 500, 400))
}

@Test(.gated) func pauseHoldsTheCallUntilTheGateOpens() async throws {
    let w = window(1, frame: rect(0, 0, 100, 100))
    let (fake, _) = await makeFake(w)
    let gate = await fake.pause(beforeCall: 1)
    let s = try await session(fake, w.handle)
    let write = Task { await s.setSize(ScreenSize(width: 500, height: 400), admit: admitted) }
    await gate.waitUntilHolding(1)
    #expect(await fake.callLog == ["begin"])
    #expect(await fake.windows[w.handle]?.frame == rect(0, 0, 100, 100))

    gate.open()
    #expect(try await write.bounded()?.get() == .write)
    #expect(await fake.callLog == ["begin", "size 500x400"])
    #expect(await fake.windows[w.handle]?.frame == rect(0, 0, 500, 400))
}

@Test func hungAppFails() async throws {
    let w = window(1, frame: rect(0, 0, 100, 100), pid: 100)
    let (fake, clock) = await makeFake(w)
    await fake.configure { $0.hung = [100] }

    let finished = Mutex(false)
    let attempt = Task {
        let result = await fake.beginWriting(w.handle)
        finished.withLock { $0 = true }
        return result
    }
    await clock.waitForSleepers(1)
    await clock.advance(by: .milliseconds(499))
    #expect(finished.withLock { $0 } == false)

    await clock.advance(by: .milliseconds(1))
    guard case .failure(let failure) = await attempt.bounded() else {
        Issue.record("beginWriting on a hung app succeeded")
        return
    }
    #expect(failure == .notResponding)
}

@Test func hungAppFailsReadsThroughTheSessionAndFreesTheSlot() async throws {
    let w = window(1, frame: rect(0, 0, 100, 100), pid: 100)
    let (fake, clock) = await makeFake(w)
    let s = try await session(fake, w.handle)
    await fake.configure { $0.hung = [100] }

    let read = Task { await s.readFrame(take: { $0 }) }
    await clock.waitForSleepers(1)
    await clock.advance(by: .milliseconds(500))
    #expect(await read.bounded() == .failure(.notResponding))

    await fake.configure { $0.hung = [] }
    await s.end()
    _ = try await session(fake, w.handle)
}

@Test func unknownWindowsAndNoFocus() async {
    let (fake, _) = await makeFake()
    let ghost = WindowHandle(pid: 1, windowID: 99, isStable: true)
    #expect(await fake.snapshot(of: ghost, take: { $0 }) == .failure(.noWindow))
    #expect(await fake.focusedWindow(take: { $0 }) == .failure(.noWindow))
    guard case .failure(let failure) = await fake.beginWriting(ghost) else {
        Issue.record("beginWriting on an unknown window succeeded")
        return
    }
    #expect(failure == .noWindow)
}

@Test(.timeLimit(.minutes(1))) func anAnnouncementAndAnEndReachTheNoticesAsTheirEventsAreEmitted() async {
    let w = window(1, frame: rect(0, 0, 100, 100))
    let (fake, _) = await makeFake(w)
    let owner = WindowOwner(adjustments: [])
    _ = await fake.startObserving(notices: owner)
    await fake.emit(.windowCreated(w))
    #expect(owner.knows(w.handle))
    await fake.emit(.windowDestroyed(w.handle))
    #expect(!owner.knows(w.handle))
    await fake.announce(w)
    #expect(owner.knows(w.handle))
    await fake.emit(.appQuit(pid: w.handle.pid))
    #expect(!owner.knows(w.handle))
}

@Test(.timeLimit(.minutes(1))) func eventsObservationAndUnobservedApps() async {
    let w = window(1, frame: rect(0, 0, 100, 100))
    let (fake, _) = await makeFake(w)
    _ = await fake.startObserving(notices: WindowOwner(adjustments: []))
    await fake.stopObserving()
    #expect(await fake.startObservingCount == 1)
    #expect(await fake.stopObservingCount == 1)

    await fake.configure { $0.unobserved = [.init(pid: 7, bundleID: "com.example.slow", missing: [.created])] }
    await fake.emit(.windowMoved(w.handle))
    await fake.emitUnobserved()
    let events = Collector(fake.events)
    #expect(await events.next() == .windowMoved(w.handle))
    #expect(await events.next() == .unobservable(pid: 7, bundleID: "com.example.slow", missing: [.created]))
    #expect(await fake.eventsSent == 2)
}

@Test func failureMessages() {
    let rows: [(FailureKind, String, String)] = [
        (.noWindow, "No window to move", "no-window"),
        (.notResponding(app: "Safari"), "Safari didn't respond", "not-responding"),
        (.sizeRefused(app: "Terminal"), "Terminal kept its own size", "size-refused"),
        (.cannotMove, "This window can't be moved", "cannot-move"),
        (.fullscreen, "Full-screen windows stay where they are", "fullscreen"),
        (.movedDuringPlacement, "The window was moved during placement", "moved-during-placement"),
        (.noDisplayThatWay, "No display that way", "no-display"),
        (.permissionMissing, "Tafl needs Accessibility permission", "permission-missing"),
    ]
    for (kind, message, category) in rows {
        #expect(kind.message == message)
        #expect(kind.category == category)
    }
}

@Test func systemClockMeasuresFromCreation() async throws {
    let clock = SystemClock()
    try await clock.sleep(for: .milliseconds(5))
    #expect(clock.now >= .milliseconds(5))
    #expect(clock.now < .seconds(5))
}

@Test(.gated) func cancelledCallerStillWaitsForTheGate() async throws {
    let w = window(1, frame: rect(0, 0, 100, 100))
    let (fake, _) = await makeFake(w)
    let gate = await fake.pause(beforeCall: 1)
    let s = try await session(fake, w.handle)
    let write = Task { await s.setSize(ScreenSize(width: 500, height: 400), admit: admitted) }
    await gate.waitUntilHolding(1)
    write.cancel()
    // A gate that let a cancelled caller go would drop it from the gate inside `cancel()`.
    #expect(gate.heldCount == 1)
    #expect(await fake.callLog == ["begin"])

    gate.open()
    #expect(try await write.bounded()?.get() == .write)
    #expect(await fake.callLog == ["begin", "size 500x400"])
}

@Test func cancelledHungCallStillTakesHalfASecond() async {
    let w = window(1, frame: rect(0, 0, 100, 100), pid: 100)
    let (fake, clock) = await makeFake(w)
    await fake.configure { $0.hung = [100] }
    let finished = Mutex(false)
    let attempt = Task {
        let result = await fake.beginWriting(w.handle)
        finished.withLock { $0 = true }
        return result
    }
    await clock.waitForSleepers(1)
    attempt.cancel()
    // A wait that cancellation cut short would leave the clock inside `cancel()`.
    #expect(clock.sleeperCount == 1)
    #expect(finished.withLock { $0 } == false)

    await clock.advance(by: .milliseconds(499))
    #expect(finished.withLock { $0 } == false)
    await clock.advance(by: .milliseconds(1))
    guard case .failure(let failure) = await attempt.bounded() else {
        Issue.record("beginWriting on a hung app succeeded")
        return
    }
    #expect(failure == .notResponding)
}

@Test func hungAppEndWaitsAndStillFreesTheSlot() async throws {
    let w = window(1, frame: rect(0, 0, 100, 100), pid: 100)
    let (fake, clock) = await makeFake(w)
    let s = try await session(fake, w.handle)
    await fake.configure { $0.hung = [100] }
    let finished = Mutex(false)
    let ending = Task {
        await s.end()
        finished.withLock { $0 = true }
    }
    await clock.waitForSleepers(1)
    await clock.advance(by: .milliseconds(499))
    #expect(finished.withLock { $0 } == false)
    await clock.advance(by: .milliseconds(1))
    await ending.bounded()
    #expect(await fake.callLog == ["begin", "end"])

    await fake.configure { $0.hung = [] }
    _ = try await session(fake, w.handle)
}

@Test func usingASessionAfterEndIsAnIssue() async throws {
    let w = window(1, frame: rect(0, 0, 100, 100))
    let (fake, _) = await makeFake(w)
    let s = try await session(fake, w.handle)
    await s.end()
    var result: Result<ScreenRect, PlatformFailure>?
    await withKnownIssue {
        result = await s.readFrame(take: { $0 })
    }
    #expect(result == .failure(.cannotMove))
    #expect(await fake.callLog == ["begin", "end"])
}

private final class Admissions: Sendable {
    private let value = Mutex(0)
    func ask() -> WriteGo { value.withLock { $0 += 1 }; return .write }
    var count: Int { value.withLock { $0 } }
}

/// A position write asks whether the position is settable before it asks `admit`, so a write that
/// cannot be made is never admitted.
@Test(.timeLimit(.minutes(1))) func aPositionWriteThatFailsItsSettabilityQueryIsNotAdmitted() async throws {
    let window = window(1, frame: rect(10, 10, 400, 300))
    let (fake, clock) = await makeFake(window)
    await fake.configure { $0.windows[window.handle]?.canMove = false }
    let admissions = Admissions()
    let admit: @Sendable () -> WriteGo = { admissions.ask() }
    let s = try await session(fake, window.handle)

    #expect(await s.setPosition(ScreenPoint(x: 0, y: 25), admit: admit) == .failure(.cannotMove))
    #expect(admissions.count == 0)

    await fake.configure { $0.windows[window.handle]?.canMove = true; $0.hung = [window.handle.pid] }
    let hungAppsWrite = Task { await s.setPosition(ScreenPoint(x: 0, y: 25), admit: admit) }
    await clock.waitForSleepers(1)
    await clock.advance(by: .milliseconds(500))
    #expect(await hungAppsWrite.bounded() == .failure(.notResponding))
    #expect(admissions.count == 0)
}

/// Every write-session call is logged, including a position write whose window has gone.
@Test(.timeLimit(.minutes(1))) func aPositionWriteToAWindowThatHasGoneIsLoggedAndNotAdmitted() async throws {
    let window = window(1, frame: rect(10, 10, 400, 300))
    let (fake, _) = await makeFake(window)
    let admissions = Admissions()
    let admit: @Sendable () -> WriteGo = { admissions.ask() }
    let s = try await session(fake, window.handle)
    await fake.configure { $0.windows[window.handle] = nil }

    #expect(await s.setPosition(ScreenPoint(x: 0, y: 25), admit: admit) == .failure(.noWindow))
    #expect(admissions.count == 0)
    #expect(await fake.callLog == ["begin", "position 0,25"])
}
