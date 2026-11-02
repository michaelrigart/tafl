import Synchronization
import Testing
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

@Test func forgettingWaitsForWorkAlreadyOnTheQueue() async {
    let queue = AXQueue()
    let order = Mutex<[String]>([])
    let work = Task { await queue.run(pid: 7) { order.withLock { $0.append("work") } } }
    _ = await work.value
    await queue.forget(pid: 7)
    order.withLock { $0.append("forgotten") }
    #expect(order.withLock { $0 } == ["work", "forgotten"])
}
