import Synchronization
import Testing
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
    _ = await first.result
    #expect(woken.withLock { $0 } == ["25ms"])
    #expect(clock.now == .milliseconds(25))
    #expect(clock.sleeperCount == 1)

    second.cancel()
    await #expect(throws: CancellationError.self) { try await second.value }
    #expect(woken.withLock { $0 } == ["25ms"])
}

@Test func manualClockWakesSleepersAtTheirOwnDeadlines() async throws {
    let clock = ManualClock()
    let late = Task { try await clock.sleep(for: .milliseconds(300)); return clock.now }
    let early = Task { try await clock.sleep(for: .milliseconds(100)); return clock.now }
    await clock.waitForSleepers(2)

    await clock.advance(by: .seconds(1))
    #expect(try await early.value == .milliseconds(100))
    #expect(try await late.value == .milliseconds(300))
    #expect(clock.now == .seconds(1))
}

@Test func manualClockRunsChainedSleepsInsideOneAdvance() async throws {
    let clock = ManualClock()
    let chain = Task {
        var wakes: [Duration] = []
        for _ in 0..<4 {
            try await clock.sleep(for: .milliseconds(25))
            wakes.append(clock.now)
        }
        return wakes
    }
    await clock.waitForSleepers(1)

    await clock.advance(by: .milliseconds(100))
    #expect(try await chain.value == [.milliseconds(25), .milliseconds(50), .milliseconds(75), .milliseconds(100)])
    #expect(clock.sleeperCount == 0)
    #expect(clock.now == .milliseconds(100))
}

@Test func manualClockSleepFailsWhenAlreadyCancelled() async {
    let clock = ManualClock()
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await clock.sleep(for: .seconds(1))
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(clock.sleeperCount == 0)
}

@Test func waitForSleepersRecordsAnIssueOnTimeout() async {
    let clock = ManualClock()
    await withKnownIssue {
        await clock.waitForSleepers(1, timeout: .milliseconds(50))
    }
}
