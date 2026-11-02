/// One write session per app at a time: Enhanced UI is per app, so two sessions would undo each
/// other's switch. Waiters take their turn in order.
actor WriteLeases {
    private var held = Set<Int32>()
    private var waiting: [Int32: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(pid: Int32) async {
        if held.insert(pid).inserted { return }
        await withCheckedContinuation { waiting[pid, default: []].append($0) }
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
