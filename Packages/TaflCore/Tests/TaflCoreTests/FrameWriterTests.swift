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

private final class Recorder: Sendable {
    private let logs = Mutex<[[String]]>([])
    func record(_ log: [String]) { logs.withLock { $0.append(log) } }
    var all: [[String]] { logs.withLock { $0 } }
}

private struct Rig {
    let clock = ManualClock()
    let fake: FakePlatform
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
        writer = FrameWriter(platform: fake, clock: clock, adjustments: adjustments, reapplyDelay: reapplyDelay)
    }

    func start(_ job: WriteJob, before: @escaping @Sendable () async -> Void = {}) -> Task<WriteResult, Never> {
        Task { [writer] in await writer.write(job, beforeFirstWrite: before) }
    }

    var log: [String] { get async { await fake.callLog } }
}

private func job(
    start: ScreenRect,
    target: ScreenRect,
    visible: ScreenRect = v,
    crosses: Bool = false,
    minSize: ScreenSize? = nil
) -> WriteJob {
    WriteJob(
        window: handle, appName: "Example", start: start, target: target, targetVisible: visible,
        crossesDisplays: crosses, minSize: minSize, displays: bothDisplays
    )
}

private func crossJob() -> WriteJob {
    job(start: crossStart, target: crossTarget, visible: bVisible, crosses: true)
}

/// An app that sizes in steps of 20: asked for 1210 wide, it gives 1200, so a cross-display pass ends 10 short.
private let steppedSize: @Sendable (isolated FakePlatform) -> Void = {
    $0.sizeRule = { _, asked in ScreenSize(width: (asked.width / 20).rounded(.down) * 20, height: asked.height) }
}
private let steppedTarget = rect(1000, 0, 1210, 900)
private let steppedAchieved = rect(1000, 0, 1200, 900)
private let steppedLog = ["begin", "size 1210x900", "read", "position 1000,0", "read", "size 1210x900", "read", "end"]

private func steppedJob() -> WriteJob {
    job(start: crossStart, target: steppedTarget, visible: bVisible, crosses: true)
}

private func moveOrigin(to point: ScreenPoint) -> @Sendable (inout WindowSnapshot) -> Void {
    { $0.frame.origin = point }
}

// MARK: Order

@Test func sizeThenPositionAcrossDisplays() async {
    let rig = await Rig(start: crossStart, reapplyDelay: .milliseconds(25))
    let task = rig.start(crossJob())
    await rig.clock.waitForSleepers(1)
    #expect(await rig.log == crossLog)

    await rig.clock.advance(by: .milliseconds(25))
    #expect(await task.value == .placed(crossTarget))
    #expect(await rig.log == crossLog + ["begin", "read", "end"])
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
    let before = Counter()
    let result = await rig.start(job(start: target, target: target), before: { _ = before.next() }).value
    #expect(result == .placed(target))
    #expect(await rig.log == ["begin", "end"])
    #expect(before.count == 0)
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

@Test func eventDuringWriteStopsBeforeTheNextWrite() async {
    let rig = await Rig(start: crossStart)
    let gate = await rig.fake.pause(beforeCall: 2)
    let task = rig.start(crossJob())
    #expect(await pollUntil { gate.waiterCount == 1 })
    #expect(await rig.writer.isWriting(handle))

    await rig.writer.observed(handle, frame: rect(400, 400, 1200, 900))
    gate.open()
    #expect(await task.value == .interrupted)
    #expect(await rig.log == ["begin", "size 1200x900", "read", "end"])
}

@Test func anEventDifferingOnlyInTheWrittenPartIsTolerated() async {
    let rig = await Rig(start: crossStart)
    let gate = await rig.fake.pause(beforeCall: 2)
    let task = rig.start(crossJob())
    #expect(await pollUntil { gate.waiterCount == 1 })

    await rig.writer.observed(handle, frame: rect(100, 100, 1100, 900))
    gate.open()
    #expect(await task.value == .placed(crossTarget))
}

@Test func eventBeforeTheFirstWriteStopsIt() async {
    let rig = await Rig(start: crossStart)
    let gate = await rig.fake.pause(beforeCall: 0)
    let task = rig.start(crossJob())
    #expect(await pollUntil { gate.waiterCount == 1 })

    await rig.writer.observed(handle, frame: rect(400, 400, 400, 300))
    gate.open()
    #expect(await task.value == .interrupted)
    #expect(await rig.log == ["begin", "end"])
}

@Test func eventsAreIgnoredWhileNothingIsWriting() async {
    let rig = await Rig(start: crossStart)
    #expect(await !rig.writer.isWriting(handle))
    await rig.writer.observed(handle, frame: rect(400, 400, 400, 300))

    #expect(await rig.start(crossJob()).value == .placed(crossTarget))
    #expect(await !rig.writer.isWriting(handle))
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

@Test func reapplyDroppedWhenMoved() async {
    // Left alone the reapply would write the size again, so a write after the first session shows it ran.
    let rig = await Rig(start: crossStart, reapplyDelay: .milliseconds(25), configure: steppedSize)
    let task = rig.start(steppedJob())
    await rig.clock.waitForSleepers(1)
    await rig.fake.configure { $0.windows[handle]?.frame.origin = ScreenPoint(x: 1100, y: 50) }

    await rig.clock.advance(by: .milliseconds(25))
    #expect(await task.value == .placed(steppedAchieved))
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
    #expect(await rig.log == steppedLog + ["begin", "read", "end"])
}

@Test func reapplyDroppedOnReconfiguration() async {
    let rig = await Rig(start: crossStart, reapplyDelay: .milliseconds(25))
    let task = rig.start(crossJob())
    await rig.clock.waitForSleepers(1)
    await rig.writer.reconfigurationBegan()

    await rig.clock.advance(by: .milliseconds(25))
    #expect(await task.value == .placed(crossTarget))
    #expect(await rig.log == crossLog)
}

@Test func reapplyDroppedByCancellation() async {
    let rig = await Rig(start: crossStart, reapplyDelay: .milliseconds(25))
    let task = rig.start(crossJob())
    await rig.clock.waitForSleepers(1)
    task.cancel()

    #expect(await task.value == .placed(crossTarget))
    #expect(await rig.log == crossLog)
}

@Test func beforeFirstWriteRunsOnceBeforeTheFirstWrite() async {
    let rig = await Rig(start: crossStart, reapplyDelay: .milliseconds(25))
    let seen = Recorder()
    let task = rig.start(crossJob()) { [fake = rig.fake] in seen.record(await fake.callLog) }
    await rig.clock.waitForSleepers(1)
    await rig.clock.advance(by: .milliseconds(25))
    _ = await task.value
    #expect(seen.all == [["begin"]])
}

// MARK: Failures and exits

@Test func hungAppFailsWithoutWriting() async {
    let rig = await Rig(start: crossStart) { $0.hung = [100] }
    let before = Counter()
    let task = rig.start(crossJob(), before: { _ = before.next() })
    await rig.clock.waitForSleepers(1)
    await rig.clock.advance(by: .milliseconds(500))

    #expect(await task.value == .failed(.notResponding, lastVerified: nil))
    #expect(await rig.log == ["begin"])
    #expect(before.count == 0)
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

@Test func cancelledBeforeTheFirstWriteWritesNothing() async {
    let rig = await Rig(start: crossStart)
    let gate = await rig.fake.pause(beforeCall: 0)
    let before = Counter()
    let task = rig.start(crossJob(), before: { _ = before.next() })
    #expect(await pollUntil { gate.waiterCount == 1 })
    task.cancel()
    gate.open()

    #expect(await task.value == .cancelled(lastVerified: nil))
    #expect(await rig.log == ["begin", "end"])
    #expect(before.count == 0)
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
        if exit == .cancellation { task.cancel() } else { await rig.writer.reconfigurationBegan() }
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
