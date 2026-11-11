import Foundation
import Synchronization
import Testing
import TaflTestSupport
@testable import TaflCore

private let handle = WindowHandle(pid: 100, windowID: 1, isStable: true)
private let other = WindowHandle(pid: 200, windowID: 2, isStable: true)

private final class Flag: Sendable {
    private let value = Mutex(false)
    func set() { value.withLock { $0 = true } }
    var isSet: Bool { value.withLock { $0 } }
}

private func waitForRequests(_ queue: WindowRequestQueue, _ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
    await waitUntil("\(count) requests to the queue", sourceLocation: sourceLocation) { await queue.requestCount >= count }
}

/// Holds a request's body until a newer request cancels it.
private func untilCancelled(sourceLocation: SourceLocation = #_sourceLocation) async {
    await waitUntilCancelled("a newer request to cancel this one", sourceLocation: sourceLocation)
}

@Test(.gated) func newerRequestWaitsForTheCallInFlight() async throws {
    let clock = ManualClock()
    let fake = FakePlatform(clock: clock, displays: [displayA])
    await fake.configure { $0.windows[handle] = window(1, frame: rect(0, 25, 500, 775)) }
    let gate = await fake.pause(beforeCall: 1)
    let queue = WindowRequestQueue()
    let started = Flag()

    // The first request ends its loop only once a newer one has cancelled it, then makes a call that is held.
    let first = Task {
        await queue.run(handle) {
            guard let session = try? await fake.beginWriting(handle).get() else { return "no session" }
            started.set()
            await untilCancelled()
            _ = await session.readFrame(take: { $0 })
            await session.end()
            return "first"
        }
    }
    await waitUntil("the first request to start") { started.isSet }
    let second = Task { await queue.run(handle) { await fake.callLog } }
    await gate.waitUntilHolding(1)
    gate.open()

    #expect(await first.bounded() == .some(nil))
    #expect(await second.bounded() == ["begin", "read", "end"])
}

@Test func reapplyDroppedByNewerRequest() async {
    let clock = ManualClock()
    let fake = FakePlatform(clock: clock, displays: [displayA, displayB])
    await fake.configure {
        $0.windows[handle] = window(1, frame: rect(100, 100, 400, 300))
        // The app sizes in steps of 20, so the first pass ends short and a reapply is pending.
        $0.sizeRule = { _, asked in ScreenSize(width: (asked.width / 20).rounded(.down) * 20, height: asked.height) }
    }
    let owner = WindowOwner(adjustments: [])
    let writer = FrameWriter(platform: fake, clock: clock, owner: owner, reapplyDelay: .milliseconds(25))
    let queue = WindowRequestQueue()
    let start = owner.beginRequest(window(1, frame: rect(100, 100, 400, 300)))
    let job = WriteJob(
        ticket: start.ticket, appName: "Example", start: rect(100, 100, 400, 300), target: rect(1000, 0, 1210, 900),
        targetVisible: displayB.visibleFrame, crossesDisplays: true, minSize: nil, displays: [displayA, displayB]
    )

    let first = Task { await queue.run(handle) { await writer.write(job) } }
    await clock.waitForSleepers(1)
    let second = Task { await queue.run(handle) { 42 } }

    #expect(await first.bounded() == .some(nil))
    #expect(await second.bounded() == 42)
    #expect(await fake.callLog == [
        "begin", "size 1210x900", "read", "position 1000,0", "read", "size 1210x900", "read", "end",
    ])
}

@Test func aFinishedRequestReturnsItsValue() async {
    let queue = WindowRequestQueue()
    #expect(await queue.run(handle) { 1 } == 1)
    #expect(await queue.run(handle) { "again" } == "again")
}

@Test(.gated) func requestsForOtherWindowsDoNotCancelEachOther() async {
    let queue = WindowRequestQueue()
    let started = Flag()
    let release = Gate()
    let first = Task {
        await queue.run(handle) {
            started.set()
            await release.hold()
            return "first"
        }
    }
    await waitUntil("the first request to start") { started.isSet }

    #expect(await queue.run(other) { "other" } == "other")
    release.open()
    #expect(await first.bounded() == "first")
}

@Test(.gated) func aWaitingRequestCancelledBeforeItsBodyRunsReturnsNilAndNeverRuns() async {
    let queue = WindowRequestQueue()
    let started = Flag()
    let release = Gate()
    let secondRan = Flag()

    // The first request holds the window until released, but only after a newer request has cancelled it.
    let first = Task {
        await queue.run(handle) {
            started.set()
            await untilCancelled()
            await release.hold()
            return "first"
        }
    }
    await waitUntil("the first request to start") { started.isSet }
    let second = Task { await queue.run(handle) { secondRan.set(); return "second" } }
    await waitForRequests(queue, 2)
    let third = Task { await queue.run(handle) { "third" } }
    await waitForRequests(queue, 3)
    release.open()

    #expect(await first.bounded() == .some(nil))
    #expect(await second.bounded() == .some(nil))
    #expect(await third.bounded() == "third")
    #expect(!secondRan.isSet)
}
