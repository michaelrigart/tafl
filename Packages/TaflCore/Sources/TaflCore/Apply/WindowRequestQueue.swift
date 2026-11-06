import Foundation

/// Runs one request per window at a time. A newer request cancels the running one and starts
/// once that has finished, so an Accessibility call in flight returns first.
public actor WindowRequestQueue {
    private struct Entry {
        var id: Int
        var cancel: @Sendable () -> Void
        var finished: @Sendable () async -> Void
    }

    private var entries: [WindowHandle: Entry] = [:]
    private var isStopped = false
    /// How many requests have been made.
    private(set) var requestCount = 0

    public init() {}

    /// Returns nil when a newer request for the window cancelled this one, even if the body had
    /// finished by then, and straight away after `halt`.
    public func run<T: Sendable>(_ window: WindowHandle, _ body: @Sendable @escaping () async -> T) async -> T? {
        guard !isStopped else { return nil }
        let id = requestCount
        requestCount += 1
        let previous = entries[window]
        previous?.cancel()

        let task = Task { () -> T? in
            await previous?.finished()
            defer { release(window, id) }
            guard !Task.isCancelled else { return nil }
            let value = await body()
            return Task.isCancelled ? nil : value
        }
        entries[window] = Entry(id: id, cancel: { task.cancel() }, finished: { _ = await task.value })
        return await task.value
    }

    /// Refuses every later request and cancels the queued and running ones, without waiting for
    /// them: a running write stops before its next write.
    public func halt() {
        isStopped = true
        for entry in entries.values { entry.cancel() }
    }

    /// Halts, then returns once each request has finished and ended its session.
    public func stop() async {
        halt()
        for entry in Array(entries.values) { await entry.finished() }
    }

    private func release(_ window: WindowHandle, _ id: Int) {
        if entries[window]?.id == id { entries[window] = nil }
    }
}
