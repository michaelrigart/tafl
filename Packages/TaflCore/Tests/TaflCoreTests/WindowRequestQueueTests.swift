import Foundation
import Synchronization
import Testing
@testable import TaflCore

private let handle = WindowHandle(pid: 100, windowID: 1, isStable: true)
private let other = WindowHandle(pid: 200, windowID: 2, isStable: true)

private final class Flag: Sendable {
    private let value = Mutex(false)
    func set() { value.withLock { $0 = true } }
    var isSet: Bool { value.withLock { $0 } }
}

@Test func newerRequestWaitsForTheCallInFlight() async throws {
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
            while !Task.isCancelled { await Task.yield() }
            _ = await session.readFrame()
            await session.end()
            return "first"
        }
    }
    #expect(await pollUntil { started.isSet })
    let second = Task { await queue.run(handle) { await fake.callLog } }
    #expect(await pollUntil { gate.waiterCount == 1 })
    gate.open()

    #expect(await first.value == nil)
    #expect(await second.value == ["begin", "read", "end"])
}

@Test func reapplyDroppedByNewerRequest() async {
    let clock = ManualClock()
    let fake = FakePlatform(clock: clock, displays: [displayA, displayB])
    await fake.configure { $0.windows[handle] = window(1, frame: rect(100, 100, 400, 300)) }
    let writer = FrameWriter(platform: fake, clock: clock, adjustments: [], reapplyDelay: .milliseconds(25))
    let queue = WindowRequestQueue()
    let job = WriteJob(
        window: handle, appName: "Example", start: rect(100, 100, 400, 300), target: rect(1000, 0, 1200, 900),
        targetVisible: displayB.visibleFrame, crossesDisplays: true, minSize: nil, displays: [displayA, displayB]
    )

    let first = Task { await queue.run(handle) { await writer.write(job, beforeFirstWrite: {}) } }
    await clock.waitForSleepers(1)
    let second = Task { await queue.run(handle) { 42 } }

    #expect(await first.value == nil)
    #expect(await second.value == 42)
    #expect(await fake.callLog == ["begin", "size 1200x900", "read", "position 1000,0", "read", "end"])
}

@Test func aFinishedRequestReturnsItsValue() async {
    let queue = WindowRequestQueue()
    #expect(await queue.run(handle) { 1 } == 1)
    #expect(await queue.run(handle) { "again" } == "again")
}

@Test func requestsForOtherWindowsDoNotCancelEachOther() async {
    let queue = WindowRequestQueue()
    let started = Flag()
    let release = Flag()
    let first = Task {
        await queue.run(handle) {
            started.set()
            while !release.isSet { await Task.yield() }
            return "first"
        }
    }
    #expect(await pollUntil { started.isSet })

    #expect(await queue.run(other) { "other" } == "other")
    release.set()
    #expect(await first.value == "first")
}
