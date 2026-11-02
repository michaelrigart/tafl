import Synchronization
import Testing
@testable import TaflPlatform27

/// A lease queue that reports each waiter as it queues, so a test waits on that event.
private func leasesReportingWaiters() -> (WriteLeases, AsyncStream<Int32>) {
    let (queued, continuation) = AsyncStream<Int32>.makeStream()
    return (WriteLeases(didQueue: { continuation.yield($0) }), queued)
}

@Test(.timeLimit(.minutes(1)))
func aSecondLeaseForTheSameAppWaitsForTheFirstToBeReleased() async {
    let (leases, queued) = leasesReportingWaiters()
    let order = Mutex<[String]>([])
    await leases.acquire(pid: 5)
    let second = Task {
        await leases.acquire(pid: 5)
        order.withLock { $0.append("second") }
        await leases.release(pid: 5)
    }
    var queuedIterator = queued.makeAsyncIterator()
    #expect(await queuedIterator.next() == 5)
    await leases.acquire(pid: 6)
    order.withLock { $0.append("other app") }
    await leases.release(pid: 6)
    order.withLock { $0.append("first ends") }
    await leases.release(pid: 5)
    await second.value
    #expect(order.withLock { $0 } == ["other app", "first ends", "second"])
}

@Test(.timeLimit(.minutes(1)))
func waitersTakeTheirTurnInOrder() async {
    let (leases, queued) = leasesReportingWaiters()
    let order = Mutex<[Int]>([])
    await leases.acquire(pid: 5)
    var queuedIterator = queued.makeAsyncIterator()
    var tasks: [Task<Void, Never>] = []
    for index in 1...3 {
        tasks.append(Task {
            await leases.acquire(pid: 5)
            order.withLock { $0.append(index) }
            await leases.release(pid: 5)
        })
        _ = await queuedIterator.next()
    }
    await leases.release(pid: 5)
    for task in tasks { await task.value }
    #expect(order.withLock { $0 } == [1, 2, 3])
}
