import Synchronization
import Testing
import TaflTestSupport
@testable import TaflCore

/// Pins deadline-ordered resumption and cancellation, which the reapply and quiet-period
/// tests of later tasks rely on.
@Test func manualClockResumesInOrder() async {
    let clock = ManualClock()
    let woken = Mutex<[String]>([])
    let first = Task { try await clock.sleep(for: .milliseconds(25)); woken.withLock { $0.append("25ms") } }
    let second = Task { try await clock.sleep(for: .seconds(1)); woken.withLock { $0.append("1s") } }
    await clock.waitForSleepers(2)

    await clock.advance(by: .milliseconds(25))
    _ = try? await first.bounded()
    #expect(woken.withLock { $0 } == ["25ms"])
    #expect(clock.now == .milliseconds(25))
    #expect(clock.sleeperCount == 1)

    second.cancel()
    await #expect(throws: CancellationError.self) { try await second.bounded() }
    #expect(woken.withLock { $0 } == ["25ms"])
}

/// The engine's tasks read the time when they wake, as the settle wait does.
@Test func manualClockWakesSleepersAtTheirOwnDeadlines() async throws {
    let clock = ManualClock()
    let activity = EngineActivity()
    let lateUnit = activity.startingTask()
    let late = Task { await lateUnit.run { try? await clock.sleep(for: .milliseconds(300)); return clock.now } }
    let earlyUnit = activity.startingTask()
    let early = Task { await earlyUnit.run { try? await clock.sleep(for: .milliseconds(100)); return clock.now } }
    await clock.waitForSleepers(2)

    await clock.advance(by: .seconds(1))
    #expect(await early.bounded() == .milliseconds(100))
    #expect(await late.bounded() == .milliseconds(300))
    #expect(clock.now == .seconds(1))
}

/// A sleeper that is one of the engine's tasks is waited for after its wake, so a sleep it starts
/// next is due in the same advance.
@Test func manualClockRunsAnEngineTasksChainedSleepsInsideOneAdvance() async throws {
    let clock = ManualClock()
    let unit = EngineActivity().startingTask()
    let chain = Task {
        await unit.run {
            var wakes: [Duration] = []
            for _ in 0..<4 {
                try? await clock.sleep(for: .milliseconds(25))
                wakes.append(clock.now)
            }
            return wakes
        }
    }
    await clock.waitForSleepers(1)

    await clock.advance(by: .milliseconds(100))
    #expect(await chain.bounded() == [.milliseconds(25), .milliseconds(50), .milliseconds(75), .milliseconds(100)])
    #expect(clock.sleeperCount == 0)
    #expect(clock.now == .milliseconds(100))
}

private actor Hopper {
    func hop() {}
}

/// The engine's task wakes, does work across actor hops, then sleeps again. Another task registers
/// a sleep meanwhile; that must not end the wait for the engine's next sleep.
@Test(.timeLimit(.minutes(1))) func anotherTasksSleepDoesNotEndTheWaitForTheWokenEngineTask() async throws {
    let clock = ManualClock()
    let hopper = Hopper()
    let woken = Tally()
    let wakes = Mutex<[Duration]>([])
    let unit = EngineActivity().startingTask()
    let engine = Task {
        await unit.run {
            try? await clock.sleep(for: .milliseconds(100))
            wakes.withLock { $0.append(clock.now) }
            woken.increment()
            for _ in 0..<5 { await hopper.hop() }
            try? await clock.sleep(for: .milliseconds(25))
            wakes.withLock { $0.append(clock.now) }
        }
    }
    let other = Task {
        await woken.wait(for: 1, "engine wakes")
        await hopper.hop()
        try await clock.sleep(for: .seconds(5))
    }
    await clock.waitForSleepers(1)

    await clock.advance(by: .milliseconds(200))
    #expect(wakes.withLock { $0 } == [.milliseconds(100), .milliseconds(125)])
    await clock.waitForSleepers(1)
    #expect(clock.sleeperCount == 1)
    #expect(clock.now == .milliseconds(200))
    await engine.bounded()
    other.cancel()
}

@Test func manualClockSleepFailsWhenAlreadyCancelled() async {
    let clock = ManualClock()
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await clock.sleep(for: .seconds(1))
    }
    await #expect(throws: CancellationError.self) { try await task.bounded() }
    #expect(clock.sleeperCount == 0)
}

@Test func waitForSleepersRecordsAnIssueOnTimeout() async {
    let clock = ManualClock()
    await withKnownIssue {
        await clock.waitForSleepers(1, timeout: .milliseconds(50))
    }
}
