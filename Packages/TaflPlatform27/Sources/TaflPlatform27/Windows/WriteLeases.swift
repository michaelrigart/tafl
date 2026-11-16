/// One write session per app at a time: Enhanced UI is per app, so two sessions would undo each
/// other's switch. Waiters take their turn in order.
actor WriteLeases {
    private var held = Set<Int32>()
    private var waiting: [Int32: [CheckedContinuation<Void, Never>]] = [:]
    private let didQueue: @Sendable (Int32) -> Void

    /// `didQueue` is told of each waiter as it queues.
    init(didQueue: @escaping @Sendable (Int32) -> Void = { _ in }) {
        self.didQueue = didQueue
    }

    func acquire(pid: Int32) async {
        if held.insert(pid).inserted { return }
        await withCheckedContinuation { continuation in
            waiting[pid, default: []].append(continuation)
            didQueue(pid)
        }
    }

    func release(pid: Int32) {
        guard var queue = waiting[pid], !queue.isEmpty else {
            held.remove(pid)
            return
        }
        let next = queue.removeFirst()
        waiting[pid] = queue.isEmpty ? nil : queue
        next.resume()
    }
}
