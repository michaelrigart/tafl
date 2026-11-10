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

@Test(.timeLimit(.minutes(1))) func aCallIntoTheEngineIsCountedUntilItLeaves() async {
    let activity = EngineActivity()
    activity.enter()
    let quiet = Task { await activity.quiet(afterEvents: 0) }
    #expect(activity.running == 1)
    activity.leave()
    await quiet.bounded()
}

@Test(.timeLimit(.minutes(1))) func quietWaitsForTheEventsItWasToldOf() async {
    let activity = EngineActivity()
    let quiet = Task { await activity.quiet(afterEvents: 2) }
    activity.receivedEvent()
    activity.receivedEvent()
    await quiet.bounded()
    #expect(activity.eventsReceived == 2)
}

@Test(.timeLimit(.minutes(1))) func aCancelledWaitForQuietReturns() async {
    let activity = EngineActivity()
    activity.enter()
    let quiet = Task { await activity.quiet(afterEvents: 0) }
    quiet.cancel()
    await quiet.bounded()
    activity.leave()
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

@Test(.timeLimit(.minutes(1))) func aCancelledSleepOfTheEnginesTaskCountsItAgainBeforeItEnds() async {
    let clock = ManualClock()
    let activity = EngineActivity()
    let unit = activity.startingTask()
    let task = Task { await unit.run { try? await clock.sleep(for: .seconds(1)) } }
    await clock.waitForSleepers(1)
    #expect(activity.running == 0)
    task.cancel()
    #expect(activity.running == 1)
    await task.bounded()
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
