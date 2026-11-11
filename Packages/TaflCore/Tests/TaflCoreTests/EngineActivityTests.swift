import Synchronization
import Testing
import TaflTestSupport
@testable import TaflCore

/// Parks the engine's task that a gate holds, as the fake platform does.
private let parking: ParkHook = {
    guard let parked = EngineActivity.parkCurrentTask() else { return nil }
    return { parked.unpark() }
}

@Test(.timeLimit(.minutes(1))) func anIdleActivityIsQuietAtOnce() async {
    let activity = EngineActivity()
    await Task { await activity.quiet(afterEvents: 0) }.bounded()
}

@Test(.gated, .timeLimit(.minutes(1))) func aTaskIsCountedFromTheStepThatCreatesItUntilItEnds() async {
    let activity = EngineActivity()
    let gate = Gate()
    let unit = activity.startingTask()
    // Counted before the task runs: a test that waits now cannot miss it.
    #expect(activity.running == 1)
    let task = Task { await unit.run { await gate.hold() } }
    await gate.waitUntilHolding(1)
    // Held without telling the activity: it still counts as running.
    #expect(activity.running == 1)
    gate.open()
    await task.bounded()
    #expect(activity.running == 0)
}

@Test(.gated, .timeLimit(.minutes(1))) func aTaskParkedInItsOwnStepIsQuietAndCountedAgainBeforeItWakes() async {
    let activity = EngineActivity()
    let gate = Gate()
    let after = Gate()
    let unit = activity.startingTask()
    let task = Task {
        await unit.run {
            await gate.hold(parking: parking)
            // Not parked: the step after the wake keeps the task counted.
            await after.hold()
        }
    }
    await gate.waitUntilHolding(1)
    await Task { await activity.quiet(afterEvents: 0) }.bounded()
    #expect(activity.running == 0)
    gate.open()
    // The wake counted the task again before it ran on.
    #expect(activity.running == 1)
    #expect(unit.isRunning)
    after.open()
    await task.bounded()
    #expect(activity.running == 0)
}

/// The woken task must never read the engine as quiet after it ran on, so the waker counts it before
/// it resumes it. The hook here is slow, which gives a task resumed first time to look at the count.
@Test(.gated, .timeLimit(.minutes(1))) func aGateCountsAHeldTaskAgainBeforeItResumesIt() async {
    let activity = EngineActivity()
    let gate = Gate()
    let unit = activity.startingTask()
    let readAfterWake = Mutex<Int?>(nil)
    let slowParking: ParkHook = {
        guard let parked = EngineActivity.parkCurrentTask() else { return nil }
        return {
            var spins = 0
            while spins < 300_000, readAfterWake.withLock({ $0 }) == nil { spins += 1 }
            parked.unpark()
        }
    }
    let task = Task {
        await unit.run {
            await gate.hold(parking: slowParking)
            readAfterWake.withLock { $0 = activity.running }
        }
    }
    await gate.waitUntilHolding(1)
    gate.open()
    await task.bounded()
    #expect(readAfterWake.withLock { $0 } == 1)
}

@Test(.gated, .timeLimit(.minutes(1))) func workATaskAwaitsInAnotherTaskCountsAsTheTaskRunning() async {
    let activity = EngineActivity()
    let gate = Gate()
    let unit = activity.startingTask()
    let task = Task {
        await unit.run {
            // The child inherits the unit, but only the unit's own task can park it.
            await Task { await gate.hold(parking: parking) }.bounded()
        }
    }
    await gate.waitUntilHolding(1)
    #expect(activity.running == 1)
    gate.open()
    await task.bounded()
}

@Test(.gated, .timeLimit(.minutes(1))) func aCallIntoTheEngineIsAUnitOfTheCallersTask() async {
    let activity = EngineActivity()
    let gate = Gate()
    let calling = Task { await activity.call { await gate.hold(parking: parking) } }
    await gate.waitUntilHolding(1)
    // Parked in the caller's own task: quiet.
    #expect(activity.running == 0)
    gate.open()
    await calling.bounded()
    #expect(activity.running == 0)
}

@Test(.gated, .timeLimit(.minutes(1))) func aCallTheEngineMakesToItselfIsPartOfTheCallersUnit() async {
    let activity = EngineActivity()
    let gate = Gate()
    let calling = Task {
        await activity.call {
            await activity.call { await gate.hold(parking: parking) }
        }
    }
    await gate.waitUntilHolding(1)
    // One unit, parked: a second unit for the inner call would still be counted.
    #expect(activity.running == 0)
    gate.open()
    await calling.bounded()
}

@Test(.timeLimit(.minutes(1))) func quietWaitsForTheEventsItWasToldOf() async {
    let activity = EngineActivity()
    let quiet = Task { await activity.quiet(afterEvents: 2) }
    await waitUntil("the wait for quiet to be pending") { activity.waiting == 1 }
    activity.receivedEvent()
    // One event of two: the wait is still pending, with no work running.
    #expect(activity.running == 0)
    #expect(activity.waiting == 1)
    activity.receivedEvent()
    #expect(activity.waiting == 0)
    await quiet.bounded()
    #expect(activity.eventsReceived == 2)
}

@Test(.timeLimit(.minutes(1))) func aCancelledWaitForQuietReturns() async {
    let activity = EngineActivity()
    let busy = activity.startingTask()
    let quiet = Task { await activity.quiet(afterEvents: 0) }
    quiet.cancel()
    await quiet.bounded()
    await busy.run {}
}

// MARK: The clock

@Test(.timeLimit(.minutes(1))) func aSleepOfTheEnginesTaskIsQuietAndAWakeCountsItAgainFirst() async {
    let clock = ManualClock()
    let activity = EngineActivity()
    let unit = activity.startingTask()
    let task = Task { await unit.run { try? await clock.sleep(for: .seconds(1)) } }
    await clock.waitForSleepers(1)
    await Task { await activity.quiet(afterEvents: 0) }.bounded()
    await clock.advance(by: .seconds(1))
    await task.bounded()
    #expect(activity.running == 0)
}

/// As for a gate: the clock counts a sleeping engine task again before it resumes it, so the task
/// never reads the engine as quiet once it has run on. The hook gives a task resumed first time to look.
@Test(.timeLimit(.minutes(1))) func aWakeOfTheEnginesSleepingTaskCountsItBeforeItRuns() async {
    let clock = ManualClock()
    let activity = EngineActivity()
    let readAfterWake = Mutex<Int?>(nil)
    clock.beforeUnparking {
        var spins = 0
        while spins < 300_000, readAfterWake.withLock({ $0 }) == nil { spins += 1 }
    }
    let unit = activity.startingTask()
    let task = Task {
        await unit.run {
            try? await clock.sleep(for: .seconds(1))
            readAfterWake.withLock { $0 = activity.running }
        }
    }
    await clock.waitForSleepers(1)
    await clock.advance(by: .seconds(1))
    await task.bounded()
    #expect(readAfterWake.withLock { $0 } == 1)
}

@Test(.timeLimit(.minutes(1))) func aCancelledSleepOfTheEnginesTaskCountsItAgainBeforeItEnds() async {
    let clock = ManualClock()
    let activity = EngineActivity()
    // What the task reads once the cancelled sleep has woken it: the task ends right after, so the
    // count can't be read from outside without racing its end.
    let readAfterWake = Mutex<Int?>(nil)
    let unit = activity.startingTask()
    let task = Task {
        await unit.run {
            try? await clock.sleep(for: .seconds(1))
            readAfterWake.withLock { $0 = activity.running }
        }
    }
    await clock.waitForSleepers(1)
    #expect(activity.running == 0)
    task.cancel()
    await task.bounded()
    #expect(readAfterWake.withLock { $0 } == 1)
    // Nothing is left over: a count below zero would make the next wait return early.
    #expect(activity.running == 0)
}

// MARK: The engine

@Test(.timeLimit(.minutes(1))) func anEngineIsQuiescentOnceTheEventsItWasSentAreDealtWith() async {
    let clock = ManualClock()
    let fake = FakePlatform(clock: clock, displays: [displayA])
    let engine = WindowEngine(
        platform: fake, store: nil, clock: clock, timing: EngineTiming(quietPeriod: .milliseconds(1500), reapplyDelay: nil),
        steps: [], adjustments: []
    )
    await engine.start(config: .defaults)
    await fake.emit(.reconfigurationBegan)
    await fake.emit(.reconfigurationEnded)
    await Task { await engine.quiescent(afterEvents: 2) }.bounded()
    // The settle wait has started: no wait for its sleeper.
    #expect(clock.sleeperCount == 1)
    await clock.advance(by: .milliseconds(1500))
    await Task { await engine.quiescent(afterEvents: 2) }.bounded()
    #expect(await engine.isFrozen == false)
    #expect(clock.sleeperCount == 0)
}

/// The engine counts each event twice, once when `handle` returns (what `quiescent` waits on) and once
/// when the work it started is done (what `waitForEvents` waits on). With no work held they agree.
@Test(.timeLimit(.minutes(1))) func theEnginesTwoEventCountsAgreeOnceNothingIsHeld() async {
    let clock = ManualClock()
    let fake = FakePlatform(clock: clock, displays: [displayA])
    let engine = WindowEngine(
        platform: fake, store: nil, clock: clock, timing: EngineTiming(quietPeriod: .milliseconds(1500), reapplyDelay: nil),
        steps: [], adjustments: []
    )
    await engine.start(config: .defaults)
    let w = window(1, frame: rect(100, 100, 400, 300))
    await fake.configure { $0.windows[w.handle] = w }
    for event in [PlatformEvent.windowMoved(w.handle), .windowMoved(w.handle), .appLaunched(pid: 100, bundleID: "com.example.app"), .windowDestroyed(w.handle)] {
        await fake.emit(event)
    }
    await Task { await engine.quiescent(afterEvents: 4) }.bounded()
    #expect(await engine.activity.eventsReceived == 4)
    #expect(await engine.eventsHandled == 4)
}
