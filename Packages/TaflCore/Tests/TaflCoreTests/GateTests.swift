import Synchronization
import Testing
@testable import TaflTestSupport

private final class Steps: Sendable {
    private let steps = Mutex<[String]>([])
    func add(_ step: String) { steps.withLock { $0.append(step) } }
    var all: [String] { steps.withLock { $0 } }
}

@Test(.gated, .timeLimit(.minutes(1))) func aGateHoldsCallsUntilItOpensAndLetsLaterOnesThrough() async {
    let gate = Gate()
    let steps = Steps()
    let first = Task {
        await gate.hold()
        steps.add("first")
    }
    await gate.waitUntilHolding(1)
    #expect(steps.all.isEmpty)
    gate.open()
    await first.bounded()
    await gate.hold()
    #expect(steps.all == ["first"])
    #expect(gate.heldCount == 0)
}

@Test(.gated, .timeLimit(.minutes(1))) func aHeldCallIgnoresCancellationAsACallInFlightDoes() async {
    let gate = Gate()
    let held = Task { await gate.hold() }
    await gate.waitUntilHolding(1)
    held.cancel()
    // A gate that let a cancelled caller go would have dropped it inside `cancel()`.
    #expect(gate.heldCount == 1)
    gate.open()
    await held.bounded()
}

@Test(.gated, .timeLimit(.minutes(1))) func aReleaseLetsTheHeldCallsGoAndHoldsTheNext() async {
    let gate = Gate()
    let first = Task { await gate.hold() }
    await gate.waitUntilHolding(1)
    gate.release()
    await first.bounded()
    let second = Task { await gate.hold() }
    await gate.waitUntilHolding(1)
    gate.open()
    await second.bounded()
}

@Test(.gated, .timeLimit(.minutes(1))) func aHoldTellsItsParkHookAndCreditsItBeforeTheCallerGoesOn() async {
    let gate = Gate()
    let steps = Steps()
    let held = Task {
        await gate.hold(parking: {
            steps.add("parked")
            return { steps.add("woken") }
        })
        steps.add("went on")
    }
    await gate.waitUntilHolding(1)
    #expect(steps.all == ["parked"])
    gate.open()
    await held.bounded()
    #expect(steps.all == ["parked", "woken", "went on"])
    // An open gate parks nobody.
    await gate.hold(parking: {
        steps.add("parked again")
        return nil
    })
    #expect(steps.all == ["parked", "woken", "went on"])
}

@Test func aGateOutsideAGatedTestIsAnIssue() {
    withKnownIssue("nothing would open it when the test ends") {
        _ = Gate()
    }
}

@Test(.gated, .timeLimit(.minutes(1))) func waitingForMoreHeldCallsThanComeFailsAtTheBound() async {
    let gate = Gate()
    await withKnownIssue("a wait that passes its bound records an issue") {
        #expect(await gate.waitUntilHolding(1, timeout: .milliseconds(50)) == false)
    }
}

// MARK: The scope

/// Runs `body` inside a gated scope of its own, as `@Test(.gated)` runs a test.
private func inScope(bound: Duration = .seconds(30), _ body: @Sendable () async throws -> Void) async throws {
    try await GatedTrait(bound: bound).provideScope(for: Test.current!, testCase: nil, performing: body)
}

@Test(.timeLimit(.minutes(1))) func theScopeOpensItsGatesWhenTheTestReturns() async throws {
    let leftHeld = Mutex<Task<Void, Never>?>(nil)
    try await inScope {
        let gate = Gate()
        let held = Task { await gate.hold() }
        leftHeld.withLock { $0 = held }
        await gate.waitUntilHolding(1)
    }
    await leftHeld.withLock { $0 }?.bounded()
}

private struct Failure: Error {}

@Test(.timeLimit(.minutes(1))) func theScopeOpensItsGatesWhenTheTestThrows() async throws {
    let leftHeld = Mutex<Task<Void, Never>?>(nil)
    await #expect(throws: Failure.self) {
        try await inScope {
            let gate = Gate()
            let held = Task { await gate.hold() }
            leftHeld.withLock { $0 = held }
            await gate.waitUntilHolding(1)
            throw Failure()
        }
    }
    await leftHeld.withLock { $0 }?.bounded()
}

@Test(.timeLimit(.minutes(1))) func theScopeOpensItsGatesWhenTheTestIsCancelled() async throws {
    let gateMade = Tally()
    let running = Task {
        try? await inScope {
            let gate = Gate()
            gateMade.increment()
            // The test's own step is held: only the scope can let it go.
            await gate.hold()
        }
    }
    await gateMade.wait(for: 1, "gates made")
    running.cancel()
    await running.bounded()
}

@Test(.timeLimit(.minutes(1))) func theScopeOpensItsGatesAtItsBoundAndFailsTheTest() async throws {
    await withKnownIssue("a test still held at its bound records an issue") {
        try await inScope(bound: .milliseconds(100)) {
            let gate = Gate()
            // Held in the test's own step, which nothing else would let go.
            await gate.hold()
        }
    }
}
