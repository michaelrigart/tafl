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

    /// Drops the pid's queue once the work already on it has run, so a quit app leaves nothing behind.
    public func forget(pid: pid_t) async {
        guard let queue = queues.withLock({ $0[pid] }) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.queues.withLock { if $0[pid] === queue { $0[pid] = nil } }
                continuation.resume()
            }
        }
    }

    var queueCount: Int { queues.withLock { $0.count } }

    private func queue(for pid: pid_t) -> DispatchQueue {
        queues.withLock { queues in
            if let existing = queues[pid] { return existing }
            let created = DispatchQueue(label: "com.michaelrigart.tafl.ax.\(pid)")
            queues[pid] = created
            return created
        }
    }
}
