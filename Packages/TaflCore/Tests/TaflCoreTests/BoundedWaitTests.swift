import Synchronization
import Testing
import TaflTestSupport

private final class Flag: Sendable {
    private let value = Mutex(false)
    func set() { value.withLock { $0 = true } }
    var isSet: Bool { value.withLock { $0 } }
}

/// Parks callers in a checked continuation, which cancellation does not resume, until `release()`.
private final class Hold: Sendable {
    private struct State {
        var released = false
        var parked: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { state in
                if !state.released { state.parked.append(continuation) }
                return state.released
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release() {
        let parked = state.withLock { state in
            state.released = true
            defer { state.parked = [] }
            return state.parked
        }
        for continuation in parked { continuation.resume() }
    }
}

private struct Failure: Error, Equatable {}

@Test(.timeLimit(.minutes(1))) func aTaskThatEndsInTimeGivesItsValue() async {
    let task = Task { 7 }
    #expect(await task.bounded() == 7)
}

@Test(.timeLimit(.minutes(1))) func aTaskThatIgnoresCancellationEndsTheWaitAtTheBound() async {
    let release = Flag()
    // Spins until released and never looks at cancellation.
    let stuck = Task {
        while !release.isSet { await Task.yield() }
        return 7
    }
    await withKnownIssue("a wait that passes its bound records an issue") {
        #expect(await stuck.bounded(timeout: .milliseconds(100)) == nil)
    }
    release.set()
    #expect(await stuck.bounded() == 7)
}

@Test(.timeLimit(.minutes(1))) func aTaskParkedInAContinuationEndsTheWaitAtTheBound() async {
    let hold = Hold()
    let stuck = Task { await hold.wait() }
    await withKnownIssue("a wait that passes its bound records an issue") {
        await stuck.bounded(timeout: .milliseconds(100))
    }
    hold.release()
    await stuck.bounded()
}

@Test(.timeLimit(.minutes(1))) func aTimedOutWaitCancelsTheTask() async {
    let sawCancellation = Flag()
    let task = Task {
        while !Task.isCancelled { await Task.yield() }
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

@Test(.timeLimit(.minutes(1))) func aCallerCancelledBeforeTheTaskEndsStopsWaiting() async {
    let hold = Hold()
    let stuck = Task { await hold.wait() }
    let waiting = Task {
        await withKnownIssue("a cancelled wait records an issue") {
            await stuck.bounded(timeout: .seconds(30))
        }
    }
    waiting.cancel()
    await waiting.bounded()
    hold.release()
    await stuck.bounded()
}
