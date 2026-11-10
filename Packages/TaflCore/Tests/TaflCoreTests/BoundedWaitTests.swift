import Synchronization
import Testing
import TaflTestSupport

private final class Flag: Sendable {
    private let value = Mutex(false)
    func set() { value.withLock { $0 = true } }
    var isSet: Bool { value.withLock { $0 } }
}

private struct Failure: Error, Equatable {}

@Test(.timeLimit(.minutes(1))) func aTaskThatEndsInTimeGivesItsValue() async {
    let task = Task { 7 }
    #expect(await task.bounded() == 7)
}

/// A held call ignores cancellation and is parked in a continuation: the two things a time limit
/// cannot end.
@Test(.gated, .timeLimit(.minutes(1))) func aTaskThatIgnoresCancellationEndsTheWaitAtTheBound() async {
    let gate = Gate()
    let stuck = Task {
        await gate.hold()
        return 7
    }
    await withKnownIssue("a wait that passes its bound records an issue") {
        #expect(await stuck.bounded(timeout: .milliseconds(100)) == nil)
    }
    // The failed wait opened the test's gates.
    #expect(await stuck.bounded() == 7)
}

@Test(.timeLimit(.minutes(1))) func aTimedOutWaitCancelsTheTask() async {
    let sawCancellation = Flag()
    let task = Task {
        await waitUntil("the bounded wait to cancel the task", timeout: .seconds(30)) { Task.isCancelled }
        sawCancellation.set()
    }
    await withKnownIssue("a wait that passes its bound records an issue") {
        await task.bounded(timeout: .milliseconds(100))
    }
    await task.bounded()
    #expect(sawCancellation.isSet)
}

@Test(.timeLimit(.minutes(1))) func aThrowingTaskRethrowsItsError() async {
    let task = Task<Int, any Error> { throw Failure() }
    await #expect(throws: Failure.self) { try await task.bounded() }
}

@Test(.timeLimit(.minutes(1))) func aThrowingTaskThatEndsInTimeGivesItsValue() async throws {
    let task = Task<Int, any Error> { 3 }
    #expect(try await task.bounded() == 3)
}

@Test(.gated, .timeLimit(.minutes(1))) func aCallerCancelledBeforeTheTaskEndsStopsWaiting() async {
    let gate = Gate()
    let stuck = Task { await gate.hold() }
    let waiting = Task {
        await withKnownIssue("a cancelled wait records an issue") {
            await stuck.bounded(timeout: .seconds(30))
        }
    }
    waiting.cancel()
    await waiting.bounded()
    gate.open()
    await stuck.bounded()
}
