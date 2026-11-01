import ApplicationServices
import Dispatch
import Synchronization

public final class AXQueue: Sendable {
    private let queues = Mutex<[pid_t: DispatchQueue]>([:])

    public init(messagingTimeout: Float = 0.5) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout)
    }

    public func run<T: Sendable>(pid: pid_t, _ body: @Sendable @escaping () -> T) async -> T {
        let queue = queue(for: pid)
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    private func queue(for pid: pid_t) -> DispatchQueue {
        queues.withLock { queues in
            if let existing = queues[pid] { return existing }
            let created = DispatchQueue(label: "com.michaelrigart.tafl.ax.\(pid)")
            queues[pid] = created
            return created
        }
    }
}
