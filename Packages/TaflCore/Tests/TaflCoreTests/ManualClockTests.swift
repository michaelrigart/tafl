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
    #expect(woken.withLock { $0 } == ["25ms"])
    #expect(clock.now == .milliseconds(25))

    second.cancel()
    await #expect(throws: CancellationError.self) { try await second.value }
    #expect(woken.withLock { $0 } == ["25ms"])
    _ = await first.result
}

@Test func manualClockWakesSleepersInDeadlineOrder() async {
    let clock = ManualClock()
    let woken = Mutex<[String]>([])
    let late = Task { try await clock.sleep(for: .milliseconds(300)); woken.withLock { $0.append("300ms") } }
    let early = Task { try await clock.sleep(for: .milliseconds(100)); woken.withLock { $0.append("100ms") } }
    await clock.waitForSleepers(2)

    await clock.advance(by: .seconds(1))
    #expect(woken.withLock { $0 } == ["100ms", "300ms"])
    _ = await (late.result, early.result)
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
