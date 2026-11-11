import Synchronization
import Testing
import TaflTestSupport

private final class Flag: Sendable {
    private let value = Mutex(false)
    func set() { value.withLock { $0 = true } }
    var isSet: Bool { value.withLock { $0 } }
}

@Test(.timeLimit(.minutes(1))) func aConditionThatHoldsEndsTheWait() async {
    let flag = Flag()
    let setting = Task { flag.set() }
    #expect(await waitUntil("the flag to be set") { flag.isSet })
    await setting.bounded()
}

@Test(.timeLimit(.minutes(1))) func aConditionThatNeverHoldsFailsAtItsBoundNamingTheCondition() async {
    await withKnownIssue("a wait that passes its bound records an issue") {
        #expect(await waitUntil("a flag nobody sets", timeout: .milliseconds(50)) { false } == false)
    } matching: { issue in
        issue.comments.contains { $0.rawValue.contains("a flag nobody sets") }
    }
}

@Test(.timeLimit(.minutes(1))) func aCancelledWaitEndsAtOnceAndFails() async {
    let waiting = Task {
        await withKnownIssue("a cancelled wait records an issue") {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(await waitUntil("a flag nobody sets", timeout: .seconds(30)) { false } == false)
        }
    }
    await waiting.bounded()
}

/// A cancellation that lands between the wait's checks is the condition arriving, not the wait being
/// abandoned: `waitUntil { Task.isCancelled }` reports it as a cancelled wait and records an issue.
@Test(.timeLimit(.minutes(1))) func aWaitForCancellationEndsWithoutAnIssueHoweverLateTheCancelArrives() async {
    for yields in 0..<300 {
        let waiting = Task { await waitUntilCancelled("the task to be cancelled", timeout: .seconds(30)) }
        for _ in 0..<yields % 40 { await Task.yield() }
        waiting.cancel()
        await waiting.bounded()
    }
}

@Test(.timeLimit(.minutes(1))) func aWaitForCancellationThatNeverComesFailsAtItsBoundNamingTheCondition() async {
    await withKnownIssue("a wait that passes its bound records an issue") {
        await waitUntilCancelled("a cancel nobody sends", timeout: .milliseconds(50))
    } matching: { issue in
        issue.comments.contains { $0.rawValue.contains("a cancel nobody sends") }
    }
}

@Test(.gated, .timeLimit(.minutes(1))) func aFailedWaitOpensTheTestsGates() async {
    let gate = Gate()
    let held = Task { await gate.hold() }
    await gate.waitUntilHolding(1)
    await withKnownIssue("a wait that passes its bound records an issue") {
        await waitUntil("a flag nobody sets", timeout: .milliseconds(50)) { false }
    }
    // The held call goes on: a step that came after the failed wait cannot stay held.
    await held.bounded()
}
