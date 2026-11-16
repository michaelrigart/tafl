import Testing
import TaflTestSupport

@Test(.timeLimit(.minutes(1))) func aWaitEndsWhenTheTallyReachesItsTarget() async {
    let tally = Tally()
    let counting = Task {
        tally.increment()
        tally.increment()
    }
    #expect(await tally.wait(for: 2))
    await counting.bounded()
    #expect(tally.value == 2)
}

@Test(.timeLimit(.minutes(1))) func aTallyThatNeverGetsThereFailsAtTheBound() async {
    let tally = Tally()
    tally.increment()
    await withKnownIssue("a wait that passes its bound records an issue") {
        #expect(await tally.wait(for: 2, "calls", timeout: .milliseconds(50)) == false)
    } matching: { issue in
        issue.comments.contains { $0.rawValue.contains("calls of 2") }
    }
}
