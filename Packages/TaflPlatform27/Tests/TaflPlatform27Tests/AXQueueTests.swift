import Dispatch
import Synchronization
import Testing
import TaflTestSupport
@testable import TaflPlatform27

@Test func aForgottenPidLeavesNoQueueBehindOnceItsWorkHasRun() async {
    let queue = AXQueue()
    _ = await queue.run(pid: 7) { 1 }
    _ = await queue.run(pid: 8) { 2 }
    #expect(queue.queueCount == 2)
    await queue.forget(pid: 7)
    #expect(queue.queueCount == 1)
    await queue.forget(pid: 7)
    await queue.forget(pid: 99)
    #expect(queue.queueCount == 1)
}

@Test(.timeLimit(.minutes(1)))
func forgettingWaitsForWorkAlreadyOnTheQueue() async {
    let queue = AXQueue()
    let order = Mutex<[String]>([])
    let started = Tally()
    let release = DispatchSemaphore(value: 0)
    let work = Task {
        await queue.run(pid: 7) {
            started.increment()
            release.wait()
            order.withLock { $0.append("work finished") }
        }
    }
    await started.wait(for: 1, "work started")
    let queued = Tally()
    let forgetting = Task {
        await queue.forget(pid: 7, whenQueued: { queued.increment() })
        order.withLock { $0.append("forgotten") }
    }
    // Once forget has queued its drop behind the work, which is still running, the queue must still
    // be registered and forget must not have returned. A forget that never queues one fails the wait.
    await queued.wait(for: 1, "drops queued")
    #expect(queue.queueCount == 1)
    #expect(order.withLock { $0 }.isEmpty)
    release.signal()
    await work.bounded()
    await forgetting.bounded()
    #expect(order.withLock { $0 } == ["work finished", "forgotten"])
    #expect(queue.queueCount == 0)
}

@Test func queuedWorkRunsInOrderOnTheAppsQueue() async {
    let queue = AXQueue()
    let order = Mutex<[String]>([])
    queue.enqueue(pid: 7) { order.withLock { $0.append("first") } }
    queue.enqueue(pid: 7) { order.withLock { $0.append("second") } }
    // The app's queue is serial, so work run on it after both comes after both.
    await queue.run(pid: 7) { order.withLock { $0.append("after") } }
    #expect(order.withLock { $0 } == ["first", "second", "after"])
}
