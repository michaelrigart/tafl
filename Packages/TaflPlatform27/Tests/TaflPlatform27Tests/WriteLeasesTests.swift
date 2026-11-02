import ApplicationServices
import Synchronization
import Testing
import TaflCore
@testable import TaflPlatform27

@Test func aSecondLeaseForTheSameAppWaitsForTheFirstToBeReleased() async {
    let leases = WriteLeases()
    let order = Mutex<[String]>([])
    await leases.acquire(pid: 5)
    let second = Task {
        await leases.acquire(pid: 5)
        order.withLock { $0.append("second") }
        await leases.release(pid: 5)
    }
    await leases.acquire(pid: 6)
    order.withLock { $0.append("other app") }
    await leases.release(pid: 6)
    for _ in 0..<20 { await Task.yield() }
    #expect(order.withLock { $0 } == ["other app"])
    order.withLock { $0.append("first ends") }
    await leases.release(pid: 5)
    await second.value
    #expect(order.withLock { $0 } == ["other app", "first ends", "second"])
}

@Test func waitersTakeTheirTurnInOrder() async {
    let leases = WriteLeases()
    let order = Mutex<[Int]>([])
    await leases.acquire(pid: 5)
    var tasks: [Task<Void, Never>] = []
    for index in 1...3 {
        tasks.append(Task {
            await leases.acquire(pid: 5)
            order.withLock { $0.append(index) }
            await leases.release(pid: 5)
        })
        for _ in 0..<20 { await Task.yield() }
    }
    await leases.release(pid: 5)
    for task in tasks { await task.value }
    #expect(order.withLock { $0 } == [1, 2, 3])
}

@Test func registrationFailuresNameTheEventsMissing() {
    let failed: Set<String> = [kAXWindowMovedNotification, kAXUIElementDestroyedNotification, "AXSomethingElse"]
    #expect(WindowObservation27.observedEvents(for: failed) == [.moved, .destroyed])
    #expect(WindowObservation27.observedEvents(for: Set(AXObserverHub.notifications)) == [.created, .moved, .resized, .titleChanged, .destroyed])
}
