import ApplicationServices
import Synchronization
import TaflCore
import Testing
@testable import TaflPlatform27

private enum Part: CaseIterable {
    case size, position
}

/// The admission runs in the app's queue block that makes the write, so a read queued ahead of the
/// write reaches the owner first. One that is not admitted returns its answer.
@Test(.timeLimit(.minutes(1)), arguments: Part.allCases)
private func aWriteIsAdmittedOnItsAppsQueueBehindTheWorkAlreadyThere(_ part: Part) async {
    // No such process: a write that is not admitted makes no Accessibility call at all.
    let pid = pid_t(Int32.max)
    let queue = AXQueue()
    let session = WriteSession27(
        pid: pid, element: AXElementBox(AXUIElementCreateApplication(pid)), axQueue: queue,
        leases: WriteLeases(), restoresEnhancedUI: false)
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
