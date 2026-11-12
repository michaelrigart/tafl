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

    /// Queues `body` on the app's queue without waiting for it: calls for one app run in the order
    /// they were queued, behind the work already there.
    public func enqueue(pid: pid_t, _ body: @Sendable @escaping () -> Void) {
        queue(for: pid).async(execute: body)
    }

    /// Drops the pid's queue once the work already on it has run, so a quit app leaves nothing behind.
    public func forget(pid: pid_t) async {
        await forget(pid: pid, whenQueued: {})
    }

    /// `whenQueued` runs once the drop is on the app's queue behind the work already there, so a test
    /// knows `forget` has reached its drain boundary.
    func forget(pid: pid_t, whenQueued: @Sendable () -> Void) async {
        guard let queue = queues.withLock({ $0[pid] }) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.queues.withLock { if $0[pid] === queue { $0[pid] = nil } }
                continuation.resume()
            }
            whenQueued()
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
