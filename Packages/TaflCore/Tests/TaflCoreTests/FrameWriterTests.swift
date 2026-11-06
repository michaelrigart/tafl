import Foundation
import Synchronization
import Testing
@testable import TaflCore

private let handle = WindowHandle(pid: 100, windowID: 1, isStable: true)
private let bothDisplays = [displayA, displayB]
private let bVisible = displayB.visibleFrame

/// A window on A moving to B, the case that crosses displays.
private let crossStart = rect(100, 100, 400, 300)
private let crossTarget = rect(1000, 0, 1200, 900)
private let crossLog = ["begin", "size 1200x900", "read", "position 1000,0", "read", "end"]

private final class Counter: Sendable {
    private let value = Mutex(0)
    func next() -> Int { value.withLock { $0 += 1; return $0 } }
    var count: Int { value.withLock { $0 } }
}

private final class Flag: Sendable {
    private let value = Mutex(false)
    func set() { value.withLock { $0 = true } }
    var isSet: Bool { value.withLock { $0 } }
}

private struct Rig {
    let clock = ManualClock()
    let fake: FakePlatform
    let owner: WindowOwner
    let writer: FrameWriter

    init(
        start: ScreenRect,
        adjustments: [MacOSAdjustment] = MacOSAdjustment.measured27,
        reapplyDelay: Duration? = nil,
        configure: @escaping @Sendable (isolated FakePlatform) -> Void = { _ in }
    ) async {
        fake = FakePlatform(clock: clock, displays: bothDisplays)
        await fake.configure { fake in
            fake.windows[handle] = window(1, frame: start)
            configure(fake)
        }
        owner = WindowOwner(adjustments: adjustments)
        writer = FrameWriter(platform: fake, clock: clock, owner: owner, reapplyDelay: reapplyDelay)
    }

    /// Runs the job as the pipeline does: Resolve's reading of the window at the job's start begins
    /// the request, the writer writes, and the request ends. The value is what the request comes to:
    /// the writer's result, or `.interrupted` when a reading the owner judged after the writer's last
    /// step showed that someone else moved the window.
    func start(_ job: WriteJob) -> Task<WriteResult, Never> {
        Task { [writer, owner] in
            var job = job
            job.ticket = owner.beginRequest(window(1, frame: job.start)).ticket
            let result = await writer.write(job)
            return owner.endRequest(job.ticket).interrupted ? .interrupted : result
        }
    }

    /// Reads the window where it is now, through the owner, as an event's read does.
    @discardableResult
    func read() async -> ReadingVerdict? {
        let owner = owner
        return try? await fake.snapshot(of: handle) { owner.read($0) }.get()
    }

    /// Someone moves the window to `frame`, and something reads it.
    @discardableResult
    func move(to frame: ScreenRect) async -> ReadingVerdict? {
        await fake.configure { $0.windows[handle]?.frame = frame }
        return await read()
    }

    var log: [String] { get async { await fake.callLog } }
    var chain: RestoreRecord? { owner.windowMemory.restore[handle] }
}

/// The ticket is the request's; `Rig.start` begins one for it.
private func job(
    start: ScreenRect,
    target: ScreenRect,
    visible: ScreenRect = v,
    crosses: Bool = false,
    minSize: ScreenSize? = nil,
    firstWrite: FirstWrite = FirstWrite()
) -> WriteJob {
    WriteJob(
        ticket: RequestTicket(window: handle, number: 0), appName: "Example", start: start, target: target,
        targetVisible: visible, crossesDisplays: crosses, minSize: minSize, displays: bothDisplays, firstWrite: firstWrite
    )
}

private func crossJob(firstWrite: FirstWrite = FirstWrite()) -> WriteJob {
    job(start: crossStart, target: crossTarget, visible: bVisible, crosses: true, firstWrite: firstWrite)
}

/// An app that sizes in steps of 20: asked for 1210 wide, it gives 1200, so a cross-display pass ends 10 short.
private let steppedSize: @Sendable (isolated FakePlatform) -> Void = {
    $0.sizeRule = { _, asked in ScreenSize(width: (asked.width / 20).rounded(.down) * 20, height: asked.height) }
}
private let steppedTarget = rect(1000, 0, 1210, 900)
private let steppedAchieved = rect(1000, 0, 1200, 900)
private let steppedLog = ["begin", "size 1210x900", "read", "position 1000,0", "read", "size 1210x900", "read", "end"]

private func steppedJob(firstWrite: FirstWrite = FirstWrite()) -> WriteJob {
    job(start: crossStart, target: steppedTarget, visible: bVisible, crosses: true, firstWrite: firstWrite)
}

private func moveOrigin(to point: ScreenPoint) -> @Sendable (inout WindowSnapshot) -> Void {
    { $0.frame.origin = point }
}

// MARK: Order

@Test func sizeThenPositionAcrossDisplays() async {
    let rig = await Rig(start: crossStart, reapplyDelay: .milliseconds(25))
    let result = await rig.start(crossJob()).value
    #expect(result == .placed(crossTarget))
    #expect(await rig.log == crossLog)
    // Landing on the target needs no reapply.
    #expect(rig.clock.sleeperCount == 0)
}

@Test func aFirstPassWithinAPointOfTheTargetIsNotReapplied() async {
    let rig = await Rig(start: crossStart, reapplyDelay: .milliseconds(25)) {
        $0.sizeRule = { _, asked in ScreenSize(width: asked.width - 1, height: asked.height) }
    }
    let result = await rig.start(crossJob()).value
    #expect(result == .placed(rect(1000, 0, 1199, 900)))
    #expect(rig.clock.sleeperCount == 0)
}

@Test func theReapplyWritesWhatTheFirstPassFellShortOf() async {
    let rig = await Rig(start: crossStart, reapplyDelay: .milliseconds(25), configure: steppedSize)
    let task = rig.start(steppedJob())
    await rig.clock.waitForSleepers(1)
    #expect(await rig.log == steppedLog)

    await rig.clock.advance(by: .milliseconds(25))
    #expect(await task.value == .placed(steppedAchieved))
    #expect(await rig.log.suffix(7) == ["begin", "read", "size 1210x900", "read", "size 1210x900", "read", "end"])
}

@Test func positionFirstOnTheSameDisplay() async {
    let start = rect(600, 100, 300, 300)
    let target = rect(0, 25, 500, 775)
    let rig = await Rig(start: start, reapplyDelay: .milliseconds(25))
    let result = await rig.start(job(start: start, target: target)).value
    #expect(result == .placed(target))
    #expect(await rig.log == ["begin", "position 0,25", "read", "size 500x775", "read", "end"])
    #expect(rig.clock.sleeperCount == 0)
}

@Test func nothingIsWrittenForAWindowAlreadyAtTheTarget() async {
    let target = rect(0, 25, 500, 775)
    let rig = await Rig(start: target)
    let result = await rig.start(job(start: target, target: target, firstWrite: FirstWrite(opensChainOn: displayA))).value
    #expect(result == .placed(target))
    #expect(await rig.log == ["begin", "end"])
    // No write began, so no chain was opened.
    #expect(rig.chain == nil)
}

// MARK: Size

@Test func sizeRetryOnce() async {
    let start = rect(0, 25, 800, 700)
    let target = rect(0, 25, 500, 775)
    let attempts = Counter()
    let rig = await Rig(start: start) {
        $0.sizeRule = { window, asked in attempts.next() == 1 ? window.frame.size : asked }
    }
    let result = await rig.start(job(start: start, target: target)).value
    #expect(result == .placed(target))
    #expect(await rig.log.filter { $0.hasPrefix("size") } == ["size 500x775", "size 500x775"])
}

@Test func theRetryAsksForAtLeastTheMinimumSize() async {
    let start = rect(0, 25, 300, 300)
    let attempts = Counter()
    let rig = await Rig(start: start) {
        $0.sizeRule = { window, asked in attempts.next() == 1 ? window.frame.size : asked }
    }
    _ = await rig.start(job(start: start, target: rect(0, 25, 500, 775), minSize: ScreenSize(width: 600, height: 100))).value
    #expect(await rig.log.filter { $0.hasPrefix("size") } == ["size 500x775", "size 600x775"])
}

@Test func noRetryWhenTheSizeAlreadyIsTheMinimumTheAppAllows() async {
    let start = rect(0, 25, 300, 300)
    let rig = await Rig(start: start) {
        $0.sizeRule = { _, asked in ScreenSize(width: max(asked.width, 600), height: asked.height) }
    }
    let result = await rig.start(job(start: start, target: rect(0, 25, 500, 775), minSize: ScreenSize(width: 600, height: 100))).value
    #expect(result == .sizeRefused(rect(0, 25, 600, 775)))
    #expect(await rig.log == ["begin", "size 500x775", "read", "end"])
}

@Test func refusedSizeIsAlignedAndReported() async {
    // The target touches the left edge only, so the narrower window stays against it.
    let start = rect(0, 25, 800, 700)
    let wide = rect(0, 25, 1500, 775)
    let rig = await Rig(start: start) {
        $0.sizeRule = { _, asked in ScreenSize(width: min(asked.width, 600), height: asked.height) }
    }
    let result = await rig.start(job(start: start, target: rect(0, 25, 1000, 775), visible: wide)).value
    #expect(result == .sizeRefused(rect(0, 25, 600, 775)))
}

@Test func aRefusedSizeIsCentredWhenTheTargetTouchesBothEdges() async {
    let start = rect(0, 25, 800, 700)
    let rig = await Rig(start: start) {
        $0.sizeRule = { _, asked in ScreenSize(width: min(asked.width, 600), height: asked.height) }
    }
    let result = await rig.start(job(start: start, target: v)).value
    #expect(result == .sizeRefused(rect(200, 25, 600, 775)))
}

@Test func aRefusedSizeIsAlignedAfterAPositionFirstWrite() async {
    // Moving first leaves the window at the target's origin; the app then caps the width, so the retry has to
    // move the right half back against its right edge.
    let start = rect(100, 100, 300, 300)
    let rig = await Rig(start: start) {
        $0.sizeRule = { _, asked in ScreenSize(width: min(asked.width, 400), height: asked.height) }
    }
    let result = await rig.start(job(start: start, target: rect(500, 25, 500, 775))).value
    #expect(result == .sizeRefused(rect(600, 25, 400, 775)))
    #expect(await rig.log.prefix(2) == ["begin", "position 500,25"])
}

@Test(arguments: [(17.0, true), (29.0, true), (30.0, false)])
func terminalShortfallIsSuccess(shortfall: Double, isSuccess: Bool) async {
    let start = rect(0, 25, 300, 300)
    let rig = await Rig(start: start) {
        $0.sizeRule = { _, asked in ScreenSize(width: asked.width - shortfall, height: asked.height) }
    }
    let achieved = rect(0, 25, 500 - shortfall, 775)
    let result = await rig.start(job(start: start, target: rect(0, 25, 500, 775))).value
    #expect(result == (isSuccess ? .placed(achieved) : .sizeRefused(achieved)))
}

@Test func aWindowLargerThanTheTargetIsRefused() async {
    let start = rect(0, 25, 300, 300)
    let rig = await Rig(start: start) {
        $0.sizeRule = { _, asked in ScreenSize(width: max(asked.width, 505), height: asked.height) }
    }
    let result = await rig.start(job(start: start, target: rect(0, 25, 500, 775))).value
    #expect(result == .sizeRefused(rect(0, 25, 505, 775)))
}

@Test func positionRefusedIsReported() async {
    let start = rect(100, 100, 400, 300)
    let rig = await Rig(start: start) {
        $0.positionRule = { window, _ in window.frame.origin }
    }
    let result = await rig.start(job(start: start, target: rect(0, 25, 500, 775))).value
    #expect(result == .positionRefused(rect(100, 100, 500, 775)))
}

// MARK: External changes

@Test func userDragsBeforeTheReadBack() async {
    let rig = await Rig(start: crossStart) { $0.beforeCall[2] = moveOrigin(to: ScreenPoint(x: 400, y: 400)) }
    let result = await rig.start(crossJob()).value
    #expect(result == .interrupted)
    #expect(await rig.log == ["begin", "size 1200x900", "read", "end"])
}

@Test func changeAfterReadBackIsReplaced() async {
    // The stated limit: a change to only the part the next write sets is overwritten.
    let rig = await Rig(start: crossStart) { $0.beforeCall[3] = moveOrigin(to: ScreenPoint(x: 1500, y: 700)) }
    let result = await rig.start(crossJob()).value
    #expect(result == .placed(crossTarget))
    #expect(await rig.log == crossLog)
}

@Test(.timeLimit(.minutes(1))) func aMoveWhileTheSizeIsInFlightStopsBeforeTheNextWrite() async {
    let rig = await Rig(start: crossStart)
    let gate = await rig.fake.pause(beforeCall: 2)
    let task = rig.start(crossJob())
    #expect(await pollUntil { gate.waiterCount == 1 })

    #expect(await rig.move(to: rect(400, 400, 1200, 900)) == .external)
    gate.open()
    #expect(await task.value == .interrupted)
    #expect(await rig.log == ["begin", "size 1200x900", "read", "end"])
}

@Test(.timeLimit(.minutes(1))) func aReadingDifferingOnlyInThePartInFlightIsOwn() async {
    let rig = await Rig(start: crossStart)
    let gate = await rig.fake.pause(beforeCall: 2)
    let task = rig.start(crossJob())
    #expect(await pollUntil { gate.waiterCount == 1 })

    // The window passes through another width on its way to the one written.
    #expect(await rig.move(to: rect(100, 100, 1100, 900)) == .own)
    await rig.fake.configure { $0.windows[handle]?.frame = rect(100, 100, 1200, 900) }
    gate.open()
    #expect(await task.value == .placed(crossTarget))
}

@Test(.timeLimit(.minutes(1))) func aMoveWhileTheSessionBeginsStopsTheFirstWrite() async {
    let rig = await Rig(start: crossStart)
    let gate = await rig.fake.pause(beforeCall: 0)
    let task = rig.start(crossJob())
    #expect(await pollUntil { gate.waiterCount == 1 })

    #expect(await rig.move(to: rect(400, 400, 400, 300)) == .external)
    gate.open()
    #expect(await task.value == .interrupted)
    #expect(await rig.log == ["begin", "size 1200x900 interrupted", "end"])
}

private enum FirstPart: CaseIterable {
    case size, position
}

private enum UsersChange: CaseIterable {
    /// The user resizes and moves the window.
    case both
    /// The user changes only the part the first write sets: judged as if that write were in flight, it would pass.
    case writtenPartOnly
}

/// Call 1 is the first write; the window's app has a reading of it queued ahead of that write.
@Test(.timeLimit(.minutes(1)), arguments: FirstPart.allCases, UsersChange.allCases)
private func aReadingQueuedAheadOfAWriteThatFindsAnExternalChangeStopsTheWrite(_ part: FirstPart, _ change: UsersChange) async {
    let sameDisplayStart = rect(600, 100, 300, 300)
    let started = part == .size ? crossJob() : job(start: sameDisplayStart, target: rect(0, 25, 500, 775))
    let rig = await Rig(start: started.start)
    let gate = await rig.fake.pause(beforeCall: 1)
    let task = rig.start(started)
    #expect(await pollUntil { gate.waiterCount == 1 })

    // The reading queued first sees the user's change.
    let moved = rect(300, 300, 450, 350)
    let usersFrame = switch (change, part) {
    case (.both, _): moved
    case (.writtenPartOnly, .size): ScreenRect(origin: started.start.origin, size: moved.size)
    case (.writtenPartOnly, .position): ScreenRect(origin: moved.origin, size: started.start.size)
    }
    #expect(await rig.move(to: usersFrame) == .external)
    gate.open()
    #expect(await task.value == .interrupted)
    #expect(await rig.fake.windows[handle]?.frame == usersFrame)
    let write = part == .size ? "size 1200x900" : "position 0,25"
    #expect(await rig.log == ["begin", "\(write) interrupted", "end"])
}

@Test(.timeLimit(.minutes(1))) func aMoveBeforeTheRequestDoesNotStopIt() async {
    let rig = await Rig(start: crossStart)
    #expect(await rig.move(to: rect(400, 400, 400, 300)) == .first)
    #expect(await rig.move(to: crossStart) == .external)

    #expect(await rig.start(crossJob()).value == .placed(crossTarget))
}

@Test func namedAdjustmentPasses() async {
    // The app's minimum width keeps the window wider than the target; moving it onto A then clamps its width to
    // A's visible width.
    let start = rect(1100, 100, 1800, 1400)
    let clamp: @Sendable (inout WindowSnapshot) -> Void = { $0.frame.size = ScreenSize(width: 1000, height: 775) }
    let setup: @Sendable (isolated FakePlatform) -> Void = {
        $0.sizeRule = { _, asked in ScreenSize(width: max(asked.width, 1200), height: asked.height) }
        $0.beforeCall[3] = clamp
    }
    let withAdjustment = await Rig(start: start, configure: setup)
    #expect(await withAdjustment.start(job(start: start, target: v, crosses: true)).value == .placed(v))

    let without = await Rig(start: start, adjustments: [], configure: setup)
    #expect(await without.start(job(start: start, target: v, crosses: true)).value == .interrupted)
    #expect(await without.log == ["begin", "size 1000x775", "read", "position 0,25", "read", "end"])
}

// MARK: Reapply

@Test func reapplyMovedWindowIsAnExternalChange() async {
    // Left alone the reapply would write the size again, so a write after the first session shows it ran.
    let rig = await Rig(start: crossStart, reapplyDelay: .milliseconds(25), configure: steppedSize)
    let task = rig.start(steppedJob())
    await rig.clock.waitForSleepers(1)
    await rig.fake.configure { $0.windows[handle]?.frame.origin = ScreenPoint(x: 1100, y: 50) }

    await rig.clock.advance(by: .milliseconds(25))
    #expect(await task.value == .interrupted)
    #expect(await rig.log == steppedLog + ["begin", "read", "end"])
}

@Test func cancelledWhileTheReapplyBeginsKeepsTheEarlierResult() async {
    let rig = await Rig(start: crossStart, reapplyDelay: .milliseconds(25), configure: steppedSize)
    let gate = await rig.fake.pause(beforeCall: steppedLog.count)
    let task = rig.start(steppedJob())
    await rig.clock.waitForSleepers(1)
    await rig.clock.advance(by: .milliseconds(25))
    #expect(await pollUntil { gate.waiterCount == 1 })
    task.cancel()
    gate.open()

    #expect(await task.value == .placed(steppedAchieved))
    #expect(await rig.log == steppedLog + ["begin", "end"])
}

@Test func reapplyDroppedOnReconfiguration() async {
    let rig = await Rig(start: crossStart, reapplyDelay: .milliseconds(25), configure: steppedSize)
    let task = rig.start(steppedJob())
    await rig.clock.waitForSleepers(1)
    rig.owner.reconfigurationBegan()

    await rig.clock.advance(by: .milliseconds(25))
    #expect(await task.value == .placed(steppedAchieved))
    #expect(await rig.log == steppedLog)
}

@Test func reapplyDroppedByCancellation() async {
    let rig = await Rig(start: crossStart, reapplyDelay: .milliseconds(25), configure: steppedSize)
    let task = rig.start(steppedJob())
    await rig.clock.waitForSleepers(1)
    task.cancel()

    #expect(await task.value == .placed(steppedAchieved))
    #expect(await rig.log == steppedLog)
}

// MARK: The first write

@Test(.timeLimit(.minutes(1))) func theFirstWriteOpensTheChainAtTheStart() async {
    let rig = await Rig(start: crossStart, reapplyDelay: .milliseconds(25), configure: steppedSize)
    let task = rig.start(steppedJob(firstWrite: FirstWrite(opensChainOn: displayA)))
    await rig.clock.waitForSleepers(1)
    #expect(rig.chain == RestoreRecord(frame: crossStart, display: displayA.identity, visibleFrame: v, chainOpen: true))
    await rig.clock.advance(by: .milliseconds(25))
    #expect(await task.value == .placed(steppedAchieved))
    #expect(rig.chain?.frame == crossStart)
}

@Test(.timeLimit(.minutes(1))) func aRequestThatYieldsToTouchWritesNothingForATouchedWindow() async {
    let rig = await Rig(start: crossStart)
    #expect(await rig.read() == .first)
    rig.owner.touch(handle)
    let firstWrite = FirstWrite(opensChainOn: displayA, yieldsToTouch: true)
    #expect(await rig.start(crossJob(firstWrite: firstWrite)).value == .cancelled(lastVerified: nil))
    // Declined at Apply's first checkpoint: no session, so no Enhanced UI switch for nothing.
    #expect(await rig.log == [])
    #expect(await rig.fake.windows[handle]?.frame == crossStart)
    #expect(rig.chain == nil)
}

// MARK: Readings over the whole request

@Test(.timeLimit(.minutes(1))) func aReadingAtTheAchievedFrameDuringTheWaitKeepsTheReapply() async {
    let rig = await Rig(start: crossStart, reapplyDelay: .milliseconds(25), configure: steppedSize)
    let task = rig.start(steppedJob())
    await rig.clock.waitForSleepers(1)
    #expect(await rig.read() == .own)

    await rig.clock.advance(by: .milliseconds(25))
    #expect(await task.value == .placed(steppedAchieved))
    #expect(await rig.log.suffix(7) == ["begin", "read", "size 1210x900", "read", "size 1210x900", "read", "end"])
}

@Test(.timeLimit(.minutes(1))) func aMoveDuringTheWaitDropsTheReapply() async {
    let rig = await Rig(start: crossStart, reapplyDelay: .milliseconds(25), configure: steppedSize)
    let task = rig.start(steppedJob())
    await rig.clock.waitForSleepers(1)
    #expect(await rig.move(to: rect(1100, 50, 1200, 900)) == .external)

    await rig.clock.advance(by: .milliseconds(25))
    #expect(await task.value == .interrupted)
    #expect(await rig.log == steppedLog)
}

@Test(.timeLimit(.minutes(1))) func aMoveWhileTheSessionEndsInterruptsTheRequest() async {
    let rig = await Rig(start: crossStart)
    let gate = await rig.fake.pause(beforeCall: 5)
    let task = rig.start(crossJob())
    #expect(await pollUntil { gate.waiterCount == 1 })
    #expect(await rig.move(to: rect(1500, 700, 1200, 900)) == .external)
    gate.open()

    #expect(await task.value == .interrupted)
}

@Test(.timeLimit(.minutes(1))) func aReadingOfTheAchievedFrameWhileTheSessionEndsIsOwn() async {
    let rig = await Rig(start: crossStart)
    let gate = await rig.fake.pause(beforeCall: 5)
    let task = rig.start(crossJob())
    #expect(await pollUntil { gate.waiterCount == 1 })
    #expect(await rig.read() == .own)
    gate.open()

    #expect(await task.value == .placed(crossTarget))
}

@Test(.timeLimit(.minutes(1))) func aMoveDuringAnAttemptWithNothingToWriteInterruptsIt() async {
    let target = rect(0, 25, 500, 775)
    let rig = await Rig(start: target)
    let gate = await rig.fake.pause(beforeCall: 0)
    let task = rig.start(job(start: target, target: target))
    #expect(await pollUntil { gate.waiterCount == 1 })
    #expect(await rig.move(to: rect(300, 300, 500, 775)) == .external)
    gate.open()

    #expect(await task.value == .interrupted)
    #expect(await rig.log == ["begin", "end"])
}

@Test(.timeLimit(.minutes(1))) func aReadingIsTaflsOwnWithinAPointOfTheNewestFrame() async {
    let rig = await Rig(start: crossStart)
    // The first reading Tafl has of a window is no move.
    #expect(await rig.read() == .first)

    #expect(await rig.start(crossJob()).value == .placed(crossTarget))
    // After the request, the achieved frame is Tafl's own and anything else is someone else's.
    #expect(await rig.read() == .own)
    #expect(await rig.move(to: rect(1000.5, 0, 1200, 899.5)) == .own)
    #expect(!rig.owner.isTouched(handle))
    #expect(await rig.move(to: rect(1002, 0, 1200, 900)) == .external)
    #expect(rig.owner.isTouched(handle))
}

// MARK: From Resolve's read

@Test(.timeLimit(.minutes(1))) func aMoveAfterResolveStopsTheRequestBeforeItOpensASession() async {
    let rig = await Rig(start: crossStart)
    var started = crossJob()
    started.ticket = rig.owner.beginRequest(window(1, frame: crossStart)).ticket
    #expect(await rig.move(to: rect(400, 400, 400, 300)) == .external)

    #expect(await rig.writer.write(started) == .interrupted)
    #expect(await rig.log == [])
    #expect(rig.owner.endRequest(started.ticket).interrupted)
}

// MARK: Before the first write

private enum During: CaseIterable {
    case cancel, reconfigure, externalMove, unchangedStart
}

@Test(arguments: During.allCases)
private func aChangeWhileTheSessionBeginsIsJudgedBeforeTheFirstWrite(_ during: During) async {
    let rig = await Rig(start: crossStart)
    let gate = await rig.fake.pause(beforeCall: 0)
    let task = rig.start(crossJob())
    #expect(await pollUntil { gate.waiterCount == 1 })
    switch during {
    case .cancel: task.cancel()
    case .reconfigure: rig.owner.reconfigurationBegan()
    case .externalMove: await rig.move(to: rect(400, 400, 400, 300))
    case .unchangedStart: await rig.read()
    }
    gate.open()

    let result = await task.value
    switch during {
    case .cancel:
        #expect(result == .cancelled(lastVerified: nil))
        #expect(await rig.log == ["begin", "end"])
    case .reconfigure:
        #expect(result == .cancelled(lastVerified: nil))
        #expect(await rig.log == ["begin", "size 1200x900 cancelled", "end"])
    case .externalMove:
        #expect(result == .interrupted)
        #expect(await rig.log == ["begin", "size 1200x900 interrupted", "end"])
    case .unchangedStart:
        #expect(result == .placed(crossTarget))
        #expect(await rig.log == crossLog)
    }
}

// MARK: Placing with the size asked for

/// A window is limited to the room left on the display holding its origin (AppKit's screen constraint).
private let screenLimited: @Sendable (isolated FakePlatform) -> Void = {
    $0.sizeRule = { window, asked in
        let visible = window.frame.origin.x >= 1000 ? bVisible : v
        return ScreenSize(
            width: min(asked.width, visible.maxX - window.frame.origin.x),
            height: min(asked.height, visible.maxY - window.frame.origin.y)
        )
    }
}

/// A size write is limited to the visible size of the display holding the window's origin.
private let displayLimited: @Sendable (isolated FakePlatform) -> Void = {
    $0.sizeRule = { window, asked in
        let visible = window.frame.origin.x >= 1000 ? bVisible : v
        return ScreenSize(width: min(asked.width, visible.width), height: min(asked.height, visible.height))
    }
}

@Test(arguments: [rect(1000, 0, 1000, 1550), rect(1000, 0, 2000, 1550)])
func aLimitedSizeIsPositionedAsIfItWereTheSizeAskedFor(target: ScreenRect) async {
    // Positioned with the size it came back with, the window would sit in the middle of the taller
    // display and the next size write would be cut off by the room left below it.
    for configure in [screenLimited, displayLimited] {
        let rig = await Rig(start: crossStart, configure: configure)
        let result = await rig.start(job(start: crossStart, target: target, visible: bVisible, crosses: true)).value
        let size = "size \(Int(target.width))x\(Int(target.height))"
        #expect(result == .placed(target))
        #expect(await rig.log == ["begin", size, "read", "position 1000,0", "read", size, "read", "end"])
    }
}

// MARK: Edges and gaps

@Test func aGapAndAGivenEdgeKeepAWindowThatKeptItsSizeAgainstTheCell() async {
    // The left-half cell with an 8-point gap: the target sits 8 points in, so it touches no edge of the
    // visible frame, yet the window stays against the cell's left edge.
    let start = rect(8, 33, 300, 300)
    let target = rect(8, 33, 492, 759)
    let capped: @Sendable (isolated FakePlatform) -> Void = {
        $0.sizeRule = { _, asked in ScreenSize(width: min(asked.width, 400), height: asked.height) }
    }
    var gapped = job(start: start, target: target)
    gapped.alignment = [.left, .top, .bottom]
    gapped.gap = 8
    let rig = await Rig(start: start, configure: capped)
    #expect(await rig.start(gapped).value == .sizeRefused(rect(8, 33, 400, 759)))

    // Without the cell's edges the target is taken to touch none, and the window is centred.
    let centred = await Rig(start: start, configure: capped)
    #expect(await centred.start(job(start: start, target: target)).value == .sizeRefused(rect(54, 33, 400, 759)))
}

// MARK: Reconfigurations

@Test(.timeLimit(.minutes(1))) func aRequestBegunBeforeAReconfigurationNeverOpensASession() async {
    let rig = await Rig(start: crossStart)
    var stale = crossJob()
    stale.ticket = rig.owner.beginRequest(window(1, frame: crossStart)).ticket
    rig.owner.reconfigurationBegan()

    #expect(await rig.writer.write(stale) == .cancelled(lastVerified: nil))
    #expect(await rig.log == [])
    rig.owner.endRequest(stale.ticket)

    #expect(await rig.start(crossJob()).value == .placed(crossTarget))
}

// MARK: Readings between any two calls

/// Reads the window where it is while the call with index `call` is held, then releases it.
private func readDuring(_ rig: Rig, call: Int, job: WriteJob) async -> (verdict: ReadingVerdict?, result: WriteResult) {
    let gate = await rig.fake.pause(beforeCall: call)
    let task = rig.start(job)
    #expect(await pollUntil { gate.waiterCount == 1 })
    let verdict = await rig.read()
    gate.open()
    return (verdict, await task.value)
}

@Test(.timeLimit(.minutes(1)), arguments: 1...5)
func aReadingBetweenAnyTwoCallsIsOwn(call: Int) async {
    let rig = await Rig(start: crossStart)
    let read = await readDuring(rig, call: call, job: crossJob())
    #expect(read.verdict == .own)
    #expect(read.result == .placed(crossTarget))
}

@Test(.timeLimit(.minutes(1)), arguments: 1...5)
func aReadingBetweenAnyTwoCallsOfAPositionFirstWriteIsOwn(call: Int) async {
    let start = rect(600, 100, 300, 300)
    let target = rect(0, 25, 500, 775)
    let rig = await Rig(start: start)
    let read = await readDuring(rig, call: call, job: job(start: start, target: target))
    #expect(read.verdict == .own)
    #expect(read.result == .placed(target))
}

@Test(.timeLimit(.minutes(1)), arguments: 1...5)
func aReadingAroundAClampIsOwn(call: Int) async {
    let start = rect(1100, 100, 1800, 1400)
    let rig = await Rig(start: start) {
        $0.sizeRule = { _, asked in ScreenSize(width: max(asked.width, 1200), height: asked.height) }
        $0.beforeCall[3] = { $0.frame.size = ScreenSize(width: 1000, height: 775) }
    }
    let read = await readDuring(rig, call: call, job: job(start: start, target: v, crosses: true))
    #expect(read.verdict == .own)
    #expect(read.result == .placed(v))
}

@Test(.timeLimit(.minutes(1))) func aMoveWhileTheSessionEndsIsExternalEvenToTheWrittenSize() async {
    let rig = await Rig(start: crossStart)
    let gate = await rig.fake.pause(beforeCall: 5)
    let task = rig.start(crossJob())
    #expect(await pollUntil { gate.waiterCount == 1 })
    #expect(await rig.move(to: rect(100, 100, 1100, 900)) == .external)
    gate.open()
    #expect(await task.value == .interrupted)
}

// MARK: What triggers and ends a reapply

@Test(.timeLimit(.minutes(1))) func aRefusedPositionIsNotReapplied() async {
    // The size also falls short, which alone would reapply; a refused position is not Rectangle's case.
    let rig = await Rig(start: crossStart, reapplyDelay: .milliseconds(25)) {
        steppedSize($0)
        $0.positionRule = { window, _ in window.frame.origin }
    }
    let finished = Flag()
    let task = rig.start(steppedJob())
    let watched = Task {
        let result = await task.value
        finished.set()
        return result
    }
    await rig.fake.waitUntil { $0.callLog.last == "end" }
    // A reapply would wait on the clock, and the request would not finish.
    let returned = await pollUntil { finished.isSet }
    if !returned { await rig.clock.advance(by: .milliseconds(25)) }
    #expect(returned)
    #expect(await watched.value == .positionRefused(rect(100, 100, 1200, 900)))
    #expect(await rig.log.filter { $0 == "begin" }.count == 1)
}

@Test func aRefusedSizeAcrossDisplaysIsReapplied() async {
    let rig = await Rig(start: crossStart, reapplyDelay: .milliseconds(25)) {
        $0.sizeRule = { _, asked in ScreenSize(width: max(asked.width, 1300), height: asked.height) }
    }
    let task = rig.start(crossJob())
    let slept = await pollUntil(timeout: .seconds(2)) { rig.clock.sleeperCount == 1 }
    #expect(slept)
    if slept { await rig.clock.advance(by: .milliseconds(25)) }
    #expect(await task.value == .sizeRefused(rect(1000, 0, 1300, 900)))
    #expect(await rig.log.filter { $0 == "begin" }.count == 2)
}

@Test(.timeLimit(.minutes(1))) func aMoveWhileAReapplyBeginsInterruptsTheRequestEvenWhenTheBeginFails() async {
    let rig = await Rig(start: crossStart, reapplyDelay: .milliseconds(25), configure: steppedSize)
    let gate = await rig.fake.pause(beforeCall: steppedLog.count)
    let task = rig.start(steppedJob())
    await rig.clock.waitForSleepers(1)
    await rig.clock.advance(by: .milliseconds(25))
    #expect(await pollUntil { gate.waiterCount == 1 })
    #expect(await rig.move(to: rect(300, 300, 1200, 900)) == .external)
    await rig.fake.configure { $0.windows[handle] = nil }
    gate.open()

    #expect(await task.value == .interrupted)
}

@Test func aReapplyWhoseBeginFailsKeepsTheEarlierResult() async {
    let rig = await Rig(start: crossStart, reapplyDelay: .milliseconds(25), configure: steppedSize)
    let gate = await rig.fake.pause(beforeCall: steppedLog.count)
    let task = rig.start(steppedJob())
    await rig.clock.waitForSleepers(1)
    await rig.clock.advance(by: .milliseconds(25))
    #expect(await pollUntil { gate.waiterCount == 1 })
    await rig.fake.configure { $0.windows[handle] = nil }
    gate.open()

    #expect(await task.value == .placed(steppedAchieved))
}

@Test func anAppThatRefusesTheSizeCannotSnapTheWindowBackUnnoticed() async {
    // The refused size write reads back the start frame, but the window has since moved: back there is
    // someone else's doing. Calls: begin, size, read, position, read, size, read, end.
    let rig = await Rig(start: crossStart) { $0.windows[handle]?.canResize = false }
    let gate = await rig.fake.pause(beforeCall: 7)
    let task = rig.start(crossJob())
    #expect(await pollUntil { gate.waiterCount == 1 })
    #expect(await rig.move(to: crossStart) == .external)
    gate.open()
    #expect(await task.value == .interrupted)
    #expect(await rig.log.count == 8)
}

@Test(.timeLimit(.minutes(1))) func aMoveDuringTheWaitInterruptsTheRequestWhenAReconfigurationEndsIt() async {
    let rig = await Rig(start: crossStart, reapplyDelay: .milliseconds(25), configure: steppedSize)
    let task = rig.start(steppedJob())
    await rig.clock.waitForSleepers(1)
    #expect(await rig.move(to: rect(300, 300, 1200, 900)) == .external)
    rig.owner.reconfigurationBegan()
    await rig.clock.advance(by: .milliseconds(25))

    #expect(await task.value == .interrupted)
    #expect(await rig.log == steppedLog)
}

@Test(.timeLimit(.minutes(1))) func aMoveDuringTheWaitInterruptsTheRequestWhenACancellationEndsIt() async {
    let rig = await Rig(start: crossStart, reapplyDelay: .milliseconds(25), configure: steppedSize)
    let task = rig.start(steppedJob())
    await rig.clock.waitForSleepers(1)
    #expect(await rig.move(to: rect(300, 300, 1200, 900)) == .external)
    task.cancel()

    #expect(await task.value == .interrupted)
    #expect(await rig.log == steppedLog)
}

// MARK: Failures and exits

@Test func hungAppFailsWithoutWriting() async {
    let rig = await Rig(start: crossStart) { $0.hung = [100] }
    let task = rig.start(crossJob(firstWrite: FirstWrite(opensChainOn: displayA)))
    await rig.clock.waitForSleepers(1)
    await rig.clock.advance(by: .milliseconds(500))

    #expect(await task.value == .failed(.notResponding, lastVerified: nil))
    #expect(await rig.log == ["begin"])
    #expect(rig.chain == nil)
}

@Test func unreadWriteVerifiesNothing() async {
    let rig = await Rig(start: crossStart)
    let gate = await rig.fake.pause(beforeCall: 4)
    let task = rig.start(crossJob())
    #expect(await pollUntil { gate.waiterCount == 1 })
    await rig.fake.configure { $0.hung = [100] }
    gate.open()
    await rig.clock.waitForSleepers(1)
    await rig.clock.advance(by: .milliseconds(500))
    // The session's end() waits on the hung app too.
    await rig.clock.waitForSleepers(1)
    await rig.clock.advance(by: .milliseconds(500))

    #expect(await task.value == .failed(.notResponding, lastVerified: nil))
}

@Test(.timeLimit(.minutes(1))) func aMoveAfterAWriteFailedMidwayIsExternal() async {
    // Size lands, then the position write fails, with nothing verified since.
    let rig = await Rig(start: crossStart) { $0.beforeCall = [2: { $0.canMove = false }] }
    #expect(await rig.start(crossJob()).value == .failed(.cannotMove, lastVerified: nil))
    // Where the size left the window is still Tafl's own; the user then drags it elsewhere.
    #expect(await rig.read() == .own)
    #expect(await rig.move(to: rect(400, 400, 400, 300)) == .external)
}

@Test func cancelledAfterTheSizeWriteKeepsTheVerifiedFrame() async {
    let rig = await Rig(start: crossStart)
    let gate = await rig.fake.pause(beforeCall: 2)
    let task = rig.start(crossJob())
    #expect(await pollUntil { gate.waiterCount == 1 })
    task.cancel()
    gate.open()

    #expect(await task.value == .cancelled(lastVerified: rect(100, 100, 1200, 900)))
    #expect(await rig.log == ["begin", "size 1200x900", "read", "end"])
}

private enum Cancellation: CaseIterable {
    case reconfiguration
    /// As the request queue cancels an older request when a newer one for the window comes.
    case newerRequest
}

@Test(arguments: Cancellation.allCases)
private func aRequestCancelledMidSequenceStillJudgesAMove(_ cancellation: Cancellation) async {
    let rig = await Rig(start: crossStart)
    let gate = await rig.fake.pause(beforeCall: 2)
    let task = rig.start(crossJob())
    #expect(await pollUntil { gate.waiterCount == 1 })
    switch cancellation {
    case .reconfiguration: rig.owner.reconfigurationBegan()
    case .newerRequest: task.cancel()
    }
    // Someone moves the window while the size's read-back is in flight.
    #expect(await rig.move(to: rect(400, 400, 1200, 900)) == .external)
    gate.open()
    #expect(await task.value == .interrupted)
    #expect(await rig.log == ["begin", "size 1200x900", "read", "end"])
}

@Test func cancelledBeforeTheFirstWriteWritesNothing() async {
    let rig = await Rig(start: crossStart)
    let gate = await rig.fake.pause(beforeCall: 0)
    let task = rig.start(crossJob(firstWrite: FirstWrite(opensChainOn: displayA)))
    #expect(await pollUntil { gate.waiterCount == 1 })
    task.cancel()
    gate.open()

    #expect(await task.value == .cancelled(lastVerified: nil))
    #expect(await rig.log == ["begin", "end"])
    #expect(rig.chain == nil)
}

private enum Exit: CaseIterable {
    case interruption, cancellation, reconfiguration, platformFailure
}

@Test(arguments: Exit.allCases)
private func sessionEndsOnEveryExit(_ exit: Exit) async {
    let rig = await Rig(start: crossStart) {
        switch exit {
        case .interruption: $0.beforeCall[2] = moveOrigin(to: ScreenPoint(x: 400, y: 400))
        case .platformFailure: $0.windows[handle]?.canMove = false
        case .cancellation, .reconfiguration: break
        }
    }
    let gate = exit == .cancellation || exit == .reconfiguration ? await rig.fake.pause(beforeCall: 2) : nil
    let task = rig.start(crossJob())
    if let gate {
        #expect(await pollUntil { gate.waiterCount == 1 })
        if exit == .cancellation { task.cancel() } else { rig.owner.reconfigurationBegan() }
        gate.open()
    }

    let result = await task.value
    switch exit {
    case .interruption: #expect(result == .interrupted)
    case .cancellation, .reconfiguration: #expect(result == .cancelled(lastVerified: rect(100, 100, 1200, 900)))
    case .platformFailure: #expect(result == .failed(.cannotMove, lastVerified: nil))
    }
    let log = await rig.log
    #expect(log.filter { $0 == "begin" }.count == 1)
    #expect(log.filter { $0 == "end" }.count == 1)
    #expect(log.last == "end")
}
