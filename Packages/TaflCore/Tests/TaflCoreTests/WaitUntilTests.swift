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
