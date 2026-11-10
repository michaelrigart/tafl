import Testing
import TaflTestSupport
@testable import TaflPlatform27

@Test func aWaitResumesWhenTheCountReachesItsTarget() async {
    let waiters = CountWaiters()
    let waiting = Task { await waiters.wait(for: 2) }
    _ = await pollUntil { waiters.waiterCount == 1 }
    waiters.increment()
    waiters.increment()
    await waiting.bounded()
    #expect(waiters.waiterCount == 0)
}

@Test func aCancelledWaitThatNeverReachedItsTargetEndsAndRecordsAnIssue() async {
    let waiters = CountWaiters()
    await withKnownIssue("a cancelled wait records an issue instead of parking forever") {
        let waiting = Task { await waiters.wait(for: 3) }
        _ = await pollUntil { waiters.waiterCount == 1 }
        waiting.cancel()
        await waiting.bounded()
    }
    #expect(waiters.waiterCount == 0)
}

@Test func aWaitStartedAlreadyCancelledEndsAndRecordsAnIssue() async {
    let waiters = CountWaiters()
    await withKnownIssue("a wait that starts cancelled records an issue") {
        let waiting = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await waiters.wait(for: 1)
        }
        await waiting.bounded()
    }
}

private func pollUntil(_ condition: () -> Bool) async -> Bool {
    let start = ContinuousClock.now
    while !condition() {
        if start.duration(to: .now) > .seconds(2) { return false }
        await Task.yield()
    }
    return true
}
