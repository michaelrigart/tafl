import Foundation
import Synchronization
import Testing
import TaflTestSupport
@testable import TaflCore

private let handle = WindowHandle(pid: 100, windowID: 1, isStable: true)
private let leftHalf = rect(0, 25, 500, 775)
private let rightHalf = rect(500, 25, 500, 775)

private final class Log: Sendable {
    private let entries = Mutex<[String]>([])
    func add(_ entry: String) { entries.withLock { $0.append(entry) } }
    var all: [String] { entries.withLock { $0 } }
}

/// Logs the rectangle it is given and returns one with `change` applied.
private struct MarkerStep: AdjustStep {
    var name: String
    var log: Log
    var change: @Sendable (ScreenRect) -> ScreenRect

    func adjust(_ placement: CalculatedPlacement, _ context: AdjustContext) -> CalculatedPlacement {
        log.add("\(name) \(placement.rect.x),\(placement.rect.y),\(placement.rect.width),\(placement.rect.height)")
        var result = placement
        result.rect = change(placement.rect)
        return result
    }
}

private func config(gap: Double = 0) -> Config {
    Config(
        shortcuts: [:], repeatMode: .displays, gap: gap, step: 30,
        menuBarIcon: true, launchAtLogin: true, layouts: []
    )
}

private func request(
    _ spec: PlacementSpec,
    on target: Display = displayA,
    placement: NamedPlacement? = nil,
    cycleStep: Int = 0,
    source: RequestSource
) -> MoveRequest {
    MoveRequest(
        window: handle, spec: spec, display: target.identity,
        placement: placement, cycleStep: cycleStep, source: source
    )
}

private func placed(_ achieved: ScreenRect, action: Action? = .leftHalf, on shown: Display = displayA) -> PlacedRecord {
    PlacedRecord(
        action: action, layout: nil, placement: .leftHalf, cycleStep: 0,
        achieved: achieved, display: shown.identity
    )
}

private func chain(_ frame: ScreenRect, open: Bool = true) -> RestoreRecord {
    RestoreRecord(frame: frame, display: displayA.identity, visibleFrame: displayA.visibleFrame, chainOpen: open)
}

private final class Seen: Sendable {
    private let value = Mutex<ScreenRect?>(nil)
    func record(_ frame: ScreenRect) { value.withLock { $0 = frame } }
    var frame: ScreenRect? { value.withLock { $0 } }
}

private struct Rig {
    let clock = ManualClock()
    let fake: FakePlatform
    let owner = WindowOwner(adjustments: MacOSAdjustment.measured27)
    let queue = WindowRequestQueue()
    let writer: FrameWriter
    let pipeline: Pipeline

    init(
        start: ScreenRect,
        displays: [Display] = [displayA],
        steps: [any AdjustStep] = [],
        memory initial: WindowMemory = WindowMemory(),
        configure: @escaping @Sendable (isolated FakePlatform) -> Void = { _ in }
    ) async {
        fake = FakePlatform(clock: clock, displays: displays)
        await fake.configure { fake in
            fake.windows[handle] = window(1, frame: start, appName: "Terminal")
            configure(fake)
        }
        writer = FrameWriter(platform: fake, clock: clock, owner: owner, reapplyDelay: nil)
        pipeline = Pipeline(platform: fake, writer: writer, queue: queue, owner: owner, steps: steps)
        owner.loadWindows(from: initial)
    }

    /// Waits until the window request queue has been asked for `count` requests in all.
    func waitForRequests(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
        let queue = queue
        await waitUntil("\(count) requests to the queue", sourceLocation: sourceLocation) { await queue.requestCount >= count }
    }

    func run(_ request: MoveRequest, gap: Double = 0) async -> PlacementOutcome {
        await pipeline.run(request, config: config(gap: gap))
    }

    func start(_ request: MoveRequest) -> Task<PlacementOutcome, Never> {
        Task { [pipeline] in await pipeline.run(request, config: config()) }
    }

    var log: [String] { get async { await fake.callLog } }
    var frame: ScreenRect { get async { await fake.windows[handle]!.frame } }
    var stored: WindowMemory { owner.windowMemory }
}

/// Moves the window as something else would, during the call this hook is set for.
private let dragged: @Sendable (inout WindowSnapshot) -> Void = {
    $0.frame.origin = ScreenPoint(x: 333, y: 444)
    $0.frame.size = ScreenSize(width: 222, height: 111)
}

// MARK: Stage order

@Test func pipelineRunsStagesInOrder() async {
    let log = Log()
    let steps: [any AdjustStep] = [
        MarkerStep(name: "first", log: log) { ScreenRect(x: $0.x, y: $0.y, width: 300, height: $0.height) },
        MarkerStep(name: "second", log: log) { ScreenRect(x: 50, y: $0.y, width: $0.width, height: $0.height) },
    ]
    let rig = await Rig(start: rect(100, 100, 400, 300), steps: steps)
    let outcome = await rig.run(request(.named(.leftHalf), source: .action(.leftHalf)))
    // The first step sees the calculated cell, the second what the first made of it.
    #expect(log.all == ["first 0.0,25.0,500.0,775.0", "second 0.0,25.0,300.0,775.0"])
    #expect(outcome == .placed(rect(50, 25, 300, 775)))
    let calls = await rig.log
    #expect(calls.contains("size 300x775"))
    #expect(calls.contains("position 50,25"))
}

@Test func gapAndMinimumSizeReachTheWriter() async {
    let steps: [any AdjustStep] = [GapStep(), MinimumSizeStep(), OnScreenStep()]
    let rig = await Rig(start: rect(100, 100, 400, 300), steps: steps)
    let outcome = await rig.run(request(.named(.leftHalf), source: .action(.leftHalf)), gap: 10)
    #expect(outcome == .placed(rect(10, 35, 485, 755)))
}

@Test func minimumSizeGrowsTheGappedCellBeforeTheWrite() async {
    let steps: [any AdjustStep] = [GapStep(), MinimumSizeStep(), OnScreenStep()]
    let rig = await Rig(start: rect(100, 100, 400, 300), steps: steps) {
        $0.windows[handle]?.minSize = ScreenSize(width: 600, height: 400)
    }
    let outcome = await rig.run(request(.named(.leftHalf), source: .action(.leftHalf)), gap: 10)
    #expect(outcome == .placed(rect(10, 35, 600, 755)))
}

@Test func gapDoesNotApplyToCenter() async {
    let steps: [any AdjustStep] = [GapStep()]
    let rig = await Rig(start: rect(0, 25, 400, 300), steps: steps)
    let outcome = await rig.run(request(.center, source: .action(.center)), gap: 10)
    #expect(outcome == .placed(rect(300, 263, 400, 300)))
}

// MARK: Resolve

@Test func noWindowFailsWithoutWriting() async {
    let rig = await Rig(start: leftHalf)
    await rig.fake.configure { $0.windows[handle] = nil }
    let outcome = await rig.run(request(.named(.rightHalf), source: .action(.rightHalf)))
    #expect(outcome == .failed(.noWindow))
    #expect(await rig.log == [])
    #expect(rig.stored.restore[handle] == nil)
}

@Test func focusedSheetCannotMove() async {
    let rig = await Rig(start: leftHalf) { $0.windows[handle]?.isSheet = true }
    let outcome = await rig.run(request(.named(.rightHalf), source: .action(.rightHalf)))
    #expect(outcome == .failed(.cannotMove))
    #expect(await rig.log == [])
}

@Test func aWindowWhosePositionCannotBeSetCannotMove() async {
    let rig = await Rig(start: leftHalf) { $0.windows[handle]?.canMove = false }
    let outcome = await rig.run(request(.named(.rightHalf), source: .action(.rightHalf)))
    #expect(outcome == .failed(.cannotMove))
    #expect(await rig.log == [])
}

@Test func fullscreenIsRefused() async {
    let rig = await Rig(start: leftHalf) { $0.windows[handle]?.isFullscreen = true }
    let outcome = await rig.run(request(.named(.rightHalf), source: .action(.rightHalf)))
    #expect(outcome == .failed(.fullscreen))
    #expect(await rig.log == [])
}

@Test func noDisplayToPlaceOnCannotMove() async {
    let rig = await Rig(start: leftHalf, displays: [])
    let outcome = await rig.run(request(.named(.rightHalf), source: .action(.rightHalf)))
    #expect(outcome == .failed(.cannotMove))
    #expect(await rig.log == [])
}

@Test func anAppThatDoesNotAnswerFailsWithTheNameThePlatformGives() async {
    let rig = await Rig(start: leftHalf) {
        $0.hung = [100]
        $0.appNames = [100: "Hung App"]
    }
    let task = rig.start(request(.named(.rightHalf), source: .action(.rightHalf)))
    await rig.clock.waitForSleepers(1)
    await rig.clock.advance(by: .milliseconds(500))
    #expect(await task.bounded() == .failed(.notResponding(app: "Hung App")))
    #expect(await rig.log == [])
}

@Test func anAppWithNoKnownNameIsCalledTheApp() async {
    let rig = await Rig(start: leftHalf) { $0.hung = [100] }
    await rig.fake.configure { $0.windows[handle] = nil }
    let task = rig.start(request(.named(.rightHalf), source: .action(.rightHalf)))
    await rig.clock.waitForSleepers(1)
    await rig.clock.advance(by: .milliseconds(500))
    #expect(await task.bounded() == .failed(.notResponding(app: "The app")))
}

@Test func planningSeesTheResolvedWindow() async {
    let memory = WindowMemory(placed: [handle: placed(leftHalf)], restore: [handle: chain(rect(10, 40, 300, 200))])
    let rig = await Rig(start: leftHalf, displays: [displayA, displayB], memory: memory)
    let seen = Mutex<ResolvedWindow?>(nil)
    let outcome = await rig.pipeline.run(handle, config: config()) { resolved in
        seen.withLock { $0 = resolved }
        return .nothing
    }
    #expect(outcome == .unchanged)
    let resolved = seen.withLock { $0 }
    #expect(resolved?.snapshot.handle == handle)
    #expect(resolved?.display == displayA)
    #expect(resolved?.displays == [displayA, displayB])
    #expect(resolved?.placed == placed(leftHalf))
    #expect(resolved?.isAtAchieved == true)
    #expect(resolved?.restoreTarget?.frame == rect(10, 40, 300, 200))
    #expect(resolved?.restoreTarget?.display == displayA)
}

@Test func aPlannedFailureIsTheOutcome() async {
    let rig = await Rig(start: leftHalf)
    let outcome = await rig.pipeline.run(handle, config: config()) { _ in .fail(.noDisplayThatWay) }
    #expect(outcome == .failed(.noDisplayThatWay))
    #expect(await rig.log == [])
}

@Test func unseenMoveStartsANewChain() async {
    // Placed at the left half, but the window sits elsewhere and no event said so.
    let moved = rect(300, 300, 400, 300)
    let memory = WindowMemory(placed: [handle: placed(leftHalf)], restore: [handle: chain(rect(10, 40, 300, 200))])
    let rig = await Rig(start: moved, memory: memory)
    let seen = Mutex<ResolvedWindow?>(nil)
    _ = await rig.pipeline.run(handle, config: config()) { resolved in
        seen.withLock { $0 = resolved }
        return .nothing
    }
    #expect(seen.withLock { $0 }?.placed == nil)
    #expect(seen.withLock { $0 }?.isAtAchieved == false)
    #expect(rig.stored.restore[handle]?.chainOpen == false)

    let outcome = await rig.run(request(.named(.rightHalf), source: .action(.rightHalf)))
    #expect(outcome == .placed(rightHalf))
    #expect(rig.stored.restore[handle]?.frame == moved)
    #expect(rig.stored.restore[handle]?.chainOpen == true)
}

// MARK: Apply

@Test func unchangedWritesNothingButRecordsThePlacementAndOpensAChain() async {
    let rig = await Rig(start: leftHalf)
    let outcome = await rig.run(request(.named(.leftHalf), placement: .leftHalf, source: .action(.leftHalf)))
    #expect(outcome == .unchanged)
    #expect(await rig.log == [])
    #expect(rig.stored.placed[handle] == placed(leftHalf))
    #expect(rig.stored.restore[handle] == chain(leftHalf))
}

@Test func unchangedKeepsAChainThatIsAlreadyOpen() async {
    let memory = WindowMemory(restore: [handle: chain(rect(10, 40, 300, 200))])
    let rig = await Rig(start: leftHalf, memory: memory)
    _ = await rig.run(request(.named(.leftHalf), placement: .leftHalf, source: .action(.leftHalf)))
    #expect(rig.stored.restore[handle] == chain(rect(10, 40, 300, 200)))
}

@Test func theNextPlanSeesAWindowAlreadyPlacedAsPlaced() async {
    let rig = await Rig(start: leftHalf)
    _ = await rig.run(request(.named(.leftHalf), placement: .leftHalf, source: .action(.leftHalf)))
    let seen = Mutex<ResolvedWindow?>(nil)
    _ = await rig.pipeline.run(handle, config: config()) { resolved in
        seen.withLock { $0 = resolved }
        return .nothing
    }
    #expect(seen.withLock { $0 }?.placed?.action == .leftHalf)
    #expect(seen.withLock { $0 }?.isAtAchieved == true)
}

@Test func anUnchangedDisplayChangeLeavesTheMemoryAlone() async {
    let rig = await Rig(start: leftHalf)
    let outcome = await rig.run(request(.named(.leftHalf), placement: .leftHalf, source: .displayChange))
    #expect(outcome == .unchanged)
    #expect(rig.stored == WindowMemory())
}

@Test func withinAPointOfTheTargetIsUnchanged() async {
    let rig = await Rig(start: rect(0.5, 25, 500, 775))
    let outcome = await rig.run(request(.named(.leftHalf), source: .action(.leftHalf)))
    #expect(outcome == .unchanged)
    #expect(await rig.log == [])
}

// MARK: Record

@Test func aPlacementRecordsTheRequestAndOpensAChain() async {
    let rig = await Rig(start: rect(100, 100, 400, 300))
    let outcome = await rig.run(request(.named(.leftHalf), placement: .leftHalf, source: .action(.leftHalf)))
    #expect(outcome == .placed(leftHalf))
    #expect(rig.stored.placed[handle] == PlacedRecord(
        action: .leftHalf, layout: nil, placement: .leftHalf, cycleStep: 0, achieved: leftHalf, display: displayA.identity
    ))
    #expect(rig.stored.restore[handle] == chain(rect(100, 100, 400, 300)))
}

@Test func aLayoutRecordsItsNameAndNoAction() async {
    let rig = await Rig(start: rect(100, 100, 400, 300))
    _ = await rig.run(request(.named(.rightHalf), placement: .rightHalf, source: .layout("work")))
    let record = rig.stored.placed[handle]
    #expect(record?.action == nil)
    #expect(record?.layout == "work")
    #expect(record?.placement == .rightHalf)
    #expect(rig.stored.restore[handle]?.chainOpen == true)
}

@Test func aNewWindowRecordsTheLayoutAndOpensAChain() async {
    let rig = await Rig(start: rect(100, 100, 400, 300))
    _ = await rig.run(request(.named(.rightHalf), placement: .rightHalf, source: .newWindow(layout: "work")))
    #expect(rig.stored.placed[handle]?.layout == "work")
    #expect(rig.stored.restore[handle]?.chainOpen == true)
}

@Test func aSizeCycleRecordsItsStep() async {
    let rig = await Rig(start: rect(100, 100, 400, 300))
    let twoThirds = GridCell(columns: 3, rows: 1, column: 0, row: 0, columnSpan: 2, rowSpan: 1)
    _ = await rig.run(request(.cell(twoThirds), cycleStep: 1, source: .action(.leftHalf)))
    let record = rig.stored.placed[handle]
    #expect(record?.cycleStep == 1)
    #expect(record?.placement == nil)
    #expect(record?.achieved == rect(0, 25, 667, 775))
}

@Test func displayMovesRecordTheirDisplayActionNotAHalf() async {
    let rig = await Rig(start: leftHalf, displays: [displayA, displayB])
    let outcome = await rig.run(request(
        .named(.leftHalf), on: displayB, placement: .leftHalf, source: .action(.displayRight)
    ))
    #expect(outcome == .placed(rect(1000, 0, 1000, 1550)))
    let record = rig.stored.placed[handle]
    #expect(record?.action == .displayRight)
    #expect(record?.placement == .leftHalf)
    #expect(record?.display == displayB.identity)
    #expect(rig.stored.restore[handle]?.display == displayA.identity)
}

@Test func displayChangeDoesNotOpenAChain() async {
    let rig = await Rig(start: leftHalf, displays: [displayA, displayB])
    let outcome = await rig.run(request(.named(.leftHalf), on: displayB, placement: .leftHalf, source: .displayChange))
    #expect(outcome == .placed(rect(1000, 0, 1000, 1550)))
    #expect(rig.stored.restore[handle] == nil)
    #expect(rig.stored.placed[handle]?.action == nil)
    #expect(rig.stored.placed[handle]?.layout == nil)
}

@Test func refusedSizeStillRecords() async {
    let rig = await Rig(start: rect(100, 100, 400, 300)) {
        $0.sizeRule = { window, _ in window.frame.size }
    }
    let outcome = await rig.run(request(.named(.leftHalf), placement: .leftHalf, source: .action(.leftHalf)))
    #expect(outcome == .failed(.sizeRefused(app: "Terminal")))
    let frame = await rig.frame
    #expect(frame.size == ScreenSize(width: 400, height: 300))
    #expect(rig.stored.restore[handle] == chain(rect(100, 100, 400, 300)))
    let record = rig.stored.placed[handle]
    #expect(record?.achieved == frame)
    #expect(record?.action == .leftHalf)
}

@Test func aRefusedPositionStillRecords() async {
    // The app puts the window where it likes: the position read back is not the aligned one.
    let rig = await Rig(start: rect(0, 25, 400, 300)) {
        $0.positionRule = { _, _ in ScreenPoint(x: 77, y: 77) }
    }
    let outcome = await rig.run(request(.named(.rightHalf), placement: .rightHalf, source: .action(.rightHalf)))
    #expect(outcome == .failed(.cannotMove))
    let frame = await rig.frame
    #expect(rig.stored.placed[handle]?.achieved == frame)
    #expect(rig.stored.restore[handle]?.chainOpen == true)
}

@Test func interruptedRecordsExternalChange() async {
    let memory = WindowMemory(placed: [handle: placed(leftHalf)], restore: [handle: chain(rect(10, 40, 300, 200))])
    let rig = await Rig(start: leftHalf, memory: memory) { $0.beforeCall = [2: dragged] }
    let outcome = await rig.run(request(.named(.rightHalf), placement: .rightHalf, source: .action(.rightHalf)))
    #expect(outcome == .failed(.movedDuringPlacement))
    #expect(rig.stored.placed[handle] == nil)
    #expect(rig.stored.restore[handle]?.chainOpen == false)
    #expect(rig.stored.restore[handle]?.frame == rect(10, 40, 300, 200))
}

@Test(.gated, .timeLimit(.minutes(1))) func aMoveTheWriterNeverSawStillKeepsItsPlacementOutOfTheMemory() async throws {
    let rig = await Rig(start: rect(100, 100, 400, 300))
    // Two writes, each read back, then the session's end (call 5), held while the user drags the window
    // and something reads it.
    let ending = await rig.fake.pause(beforeCall: 5)
    let task = rig.start(request(.named(.leftHalf), placement: .leftHalf, source: .action(.leftHalf)))
    await ending.waitUntilHolding(1)
    await rig.fake.configure { $0.windows[handle]?.frame = rect(300, 300, 400, 300) }
    let owner = rig.owner
    #expect(try await rig.fake.snapshot(of: handle) { owner.read($0) }.get() == .external)
    ending.open()
    #expect(await task.bounded() == .failed(.movedDuringPlacement))
    #expect(rig.stored.placed[handle] == nil)
    #expect(rig.stored.restore[handle]?.chainOpen == false)
}

@Test(.gated) func noWriteNoChain() async {
    let rig = await Rig(start: rect(100, 100, 400, 300))
    // The window goes away after Resolve read it, before the session begins.
    let gate = await rig.fake.pause(beforeCall: 0)
    let task = rig.start(request(.named(.leftHalf), source: .action(.leftHalf)))
    await gate.waitUntilHolding(1)
    await rig.fake.configure { $0.windows[handle] = nil }
    gate.open()
    #expect(await task.bounded() == .failed(.noWindow))
    #expect(await rig.log == ["begin"])
    #expect(rig.stored.restore[handle] == nil)
    #expect(rig.stored.placed[handle] == nil)
}

@Test(.gated) func aReconfigurationBeforeTheWriteCancelsItWithoutAChain() async {
    let rig = await Rig(start: rect(100, 100, 400, 300))
    let gate = await rig.fake.pause(beforeCall: 0)
    let task = rig.start(request(.named(.leftHalf), source: .action(.leftHalf)))
    await gate.waitUntilHolding(1)
    rig.owner.reconfigurationBegan()
    gate.open()
    #expect(await task.bounded() == .superseded)
    // The first write reaches the app, which does not make it.
    #expect(await rig.log == ["begin", "position 0,25 cancelled", "end"])
    #expect(rig.stored.restore[handle] == nil)
    #expect(rig.stored.placed[handle] == nil)
}

@Test(.gated, .timeLimit(.minutes(1))) func cancelledRequestKeepsItsRestoreFrame() async {
    let start = rect(100, 100, 400, 300)
    let rig = await Rig(start: start)
    // Held on the read after the first write: the chain is open and one part is written.
    let gate = await rig.fake.pause(beforeCall: 2)
    let first = rig.start(request(.named(.leftHalf), source: .action(.leftHalf)))
    await gate.waitUntilHolding(1)
    let second = rig.start(request(.named(.rightHalf), source: .action(.rightHalf)))
    // The queue has the second request once it has cancelled the first.
    await rig.waitForRequests(2)
    gate.open()

    #expect(await first.bounded() == .superseded)
    #expect(await second.bounded() == .placed(rightHalf))
    #expect(rig.stored.restore[handle] == chain(start))
    #expect(rig.stored.placed[handle]?.action == .rightHalf)
}

@Test(.gated, .timeLimit(.minutes(1))) func aNewerRequestStartsWhereTheWindowIsNotWhereTheOlderOnesQueuedWriteWouldPutIt() async {
    let start = rect(100, 100, 400, 300)
    let rig = await Rig(start: start)
    // The older request's first write waits on the app's queue, past every check made before it was queued.
    let gate = await rig.fake.pause(beforeCall: 1)
    let older = rig.start(request(.named(.leftHalf), source: .action(.leftHalf)))
    await gate.waitUntilHolding(1)
    let resolved = Seen()
    let newer = Task { [pipeline = rig.pipeline] in
        await pipeline.run(handle, config: config()) { window in
            resolved.record(window.snapshot.frame)
            return .request(request(.named(.rightHalf), source: .action(.rightHalf)))
        }
    }
    // The newer request has cancelled the older one, and waits for it to finish.
    await rig.waitForRequests(2)
    gate.open()

    #expect(await older.bounded() == .superseded)
    #expect(await newer.bounded() == .placed(rightHalf))
    #expect(resolved.frame == start)
    #expect(await rig.log.prefix(3) == ["begin", "position 0,25 cancelled", "end"])
    #expect(rig.stored.restore[handle] == chain(start))
}

@Test(.gated) func partialWriteCountsAsTafls() async {
    let start = rect(100, 100, 400, 300)
    let rig = await Rig(start: start)
    let gate = await rig.fake.pause(beforeCall: 2)
    let task = rig.start(request(.named(.leftHalf), source: .action(.leftHalf)))
    await gate.waitUntilHolding(1)
    rig.owner.reconfigurationBegan()
    gate.open()

    #expect(await task.bounded() == .superseded)
    let frame = await rig.frame
    #expect(frame != start)
    #expect(frame != leftHalf)
    let stored = rig.stored
    #expect(stored.isAtAchievedFrame(handle, frame: frame))
    #expect(stored.placed[handle]?.achieved == frame)
    #expect(stored.placed[handle]?.action == nil)
    #expect(stored.placed[handle]?.layout == nil)
    #expect(stored.placed[handle]?.placement == nil)
    #expect(stored.restore[handle] == chain(start))
}

@Test func aPlatformFailureAfterAWriteKeepsTheChain() async {
    // Size first (the window is flush with the target's top and left), then the position write fails.
    let rig = await Rig(start: rect(0, 25, 400, 300)) { $0.beforeCall = [2: { $0.canMove = false }] }
    let outcome = await rig.run(request(.named(.rightHalf), placement: .rightHalf, source: .action(.rightHalf)))
    #expect(outcome == .failed(.cannotMove))
    let frame = await rig.frame
    #expect(frame == rect(0, 25, 500, 775))
    #expect(rig.stored.restore[handle] == chain(rect(0, 25, 400, 300)))
}

@Test func failureAfterAWriteKeepsTheChainForTheNextRequest() async {
    let f0 = rect(10, 40, 300, 200)
    let start = rect(0, 25, 400, 300)
    let memory = WindowMemory(placed: [handle: placed(start)], restore: [handle: chain(f0)])
    // Size first, then the position write fails: the window is no longer where `placed` says.
    let rig = await Rig(start: start, memory: memory) { $0.beforeCall = [2: { $0.canMove = false }] }
    let failed = await rig.run(request(.named(.rightHalf), placement: .rightHalf, source: .action(.rightHalf)))
    #expect(failed == .failed(.cannotMove))
    #expect(await rig.frame == rect(0, 25, 500, 775))
    #expect(rig.stored.placed[handle] == nil)
    #expect(rig.stored.restore[handle] == chain(f0))

    await rig.fake.configure { $0.windows[handle]?.canMove = true }
    let next = await rig.run(request(.named(.rightHalf), placement: .rightHalf, source: .action(.rightHalf)))
    #expect(next == .placed(rightHalf))
    #expect(rig.stored.restore[handle]?.frame == f0)
}

@Test(.gated) func failureBeforeAnyWriteKeepsThePlacedRecord() async {
    let start = rect(100, 100, 400, 300)
    let memory = WindowMemory(placed: [handle: placed(start)])
    let rig = await Rig(start: start, memory: memory)
    let gate = await rig.fake.pause(beforeCall: 0)
    let task = rig.start(request(.named(.leftHalf), source: .action(.leftHalf)))
    await gate.waitUntilHolding(1)
    await rig.fake.configure { $0.windows[handle] = nil }
    gate.open()
    #expect(await task.bounded() == .failed(.noWindow))
    #expect(rig.stored.placed[handle] == placed(start))
}

// MARK: Restore

@Test func restoreCompletesOnSuccess() async {
    let memory = WindowMemory(restore: [handle: chain(rect(100, 100, 400, 300))])
    let rig = await Rig(start: leftHalf, memory: memory)
    let outcome = await rig.pipeline.run(handle, config: config()) { resolved in
        guard let target = resolved.restoreTarget else { return .nothing }
        return .request(request(.remembered(target.frame), on: target.display, source: .action(.restore)))
    }
    #expect(outcome == .placed(rect(100, 100, 400, 300)))
    #expect(rig.stored.restore[handle] == nil)
    #expect(rig.stored.placed[handle]?.action == .restore)
}

@Test func restoreAlreadyThereCompletes() async {
    let memory = WindowMemory(restore: [handle: chain(leftHalf)])
    let rig = await Rig(start: leftHalf, memory: memory)
    let outcome = await rig.run(request(.remembered(leftHalf), source: .action(.restore)))
    #expect(outcome == .unchanged)
    #expect(rig.stored.restore[handle] == nil)
    #expect(rig.stored.placed[handle]?.action == .restore)
}

@Test func restoreDoesNotOpenAChain() async {
    let rig = await Rig(start: leftHalf)
    _ = await rig.run(request(.remembered(rect(100, 100, 400, 300)), source: .action(.restore)))
    #expect(rig.stored.restore[handle] == nil)
}

@Test func aRestoreThatEndsSizeRefusedKeepsItsTarget() async {
    let target = rect(100, 100, 400, 300)
    let memory = WindowMemory(restore: [handle: chain(target)])
    let rig = await Rig(start: leftHalf, memory: memory) {
        $0.sizeRule = { window, _ in window.frame.size }
    }
    let outcome = await rig.run(request(.remembered(target), source: .action(.restore)))
    #expect(outcome == .failed(.sizeRefused(app: "Terminal")))
    #expect(rig.stored.restore[handle] == chain(target))
}

@Test func failedRestoreKeepsItsTarget() async {
    let target = rightHalf
    let memory = WindowMemory(restore: [handle: chain(target)])
    // Size first, then the position write fails: the restore wrote once and did not finish.
    let rig = await Rig(start: rect(0, 25, 400, 300), memory: memory) { $0.beforeCall = [2: { $0.canMove = false }] }
    let restore: @Sendable (ResolvedWindow) -> PlanResult = { resolved in
        guard let found = resolved.restoreTarget else { return .nothing }
        return .request(request(.remembered(found.frame), on: found.display, source: .action(.restore)))
    }
    let failed = await rig.pipeline.run(handle, config: config(), plan: restore)
    #expect(failed == .failed(.cannotMove))
    #expect(rig.stored.restore[handle]?.frame == target)

    await rig.fake.configure { $0.windows[handle]?.canMove = true }
    let retried = await rig.pipeline.run(handle, config: config(), plan: restore)
    #expect(retried == .placed(target))
    #expect(rig.stored.restore[handle] == nil)
}
