import ApplicationServices
import Dispatch
import Synchronization
import TaflCore
import Testing
import TaflTestSupport
@testable import TaflPlatform27

private enum Part: CaseIterable {
    case size, position
}

/// A session on a process that does not exist, whose settability query answers as given. A write
/// that is not admitted makes no Accessibility call at all.
private func session(
    pid: pid_t, queue: AXQueue, settable: @escaping @Sendable (AXUIElement, String) -> Result<Bool, AXFailure>
) -> WriteSession27 {
    return WriteSession27(
        pid: pid, element: AXElementBox(AXUIElementCreateApplication(pid)), axQueue: queue,
        leases: WriteLeases(), restoresEnhancedUI: false, settable: settable)
}

/// The admission runs in the app's queue block that makes the write, so a read queued ahead of the
/// write reaches the owner first. One that is not admitted returns its answer.
@Test(.timeLimit(.minutes(1)), arguments: Part.allCases)
private func aWriteIsAdmittedOnItsAppsQueueBehindTheWorkAlreadyThere(_ part: Part) async {
    let pid = pid_t(Int32.max)
    let queue = AXQueue()
    let session = session(pid: pid, queue: queue, settable: { _, _ in .success(true) })
    let order = Mutex<[String]>([])
    queue.enqueue(pid: pid) { order.withLock { $0.append("reading") } }
    let admit: @Sendable () -> WriteGo = {
        let inTask = withUnsafeCurrentTask { $0 != nil }
        order.withLock { $0.append(inTask ? "admission in the caller's task" : "admission") }
        return .interrupted
    }
    let result = switch part {
    case .size: await session.setSize(ScreenSize(width: 500, height: 400), admit: admit)
    case .position: await session.setPosition(ScreenPoint(x: 0, y: 25), admit: admit)
    }
    #expect(result == .success(.interrupted))
    #expect(order.withLock { $0 } == ["reading", "admission"])
}

/// A position write's settability query can block on a hung app. A stop that arrives meanwhile
/// (a newer request, a newer layout, a reconfiguration) refuses the write, because its admission
/// is asked after the query, immediately before the setter.
@Test(.timeLimit(.minutes(1)))
private func aStopArrivingWhileThePositionsSettabilityQueryBlocksRefusesTheWrite() async {
    let pid = pid_t(Int32.max)
    let stopped = Mutex(false)
    let release = DispatchSemaphore(value: 0)
    let (entered, enteredQuery) = AsyncStream.makeStream(of: Void.self)
    let session = session(pid: pid, queue: AXQueue(), settable: { _, _ in
        enteredQuery.yield()
        release.wait()
        return .success(true)
    })
    let write = Task {
        await session.setPosition(ScreenPoint(x: 0, y: 25), admit: { stopped.withLock { $0 } ? .cancelled : .write })
    }
    for await _ in entered { break }
    stopped.withLock { $0 = true }
    release.signal()
    #expect(await write.bounded() == .success(.cancelled))
}
