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
    private var nextID = 0

    public init() {}

    /// Returns nil when a newer request for the window cancelled this one before it finished.
    public func run<T: Sendable>(_ window: WindowHandle, _ body: @Sendable @escaping () async -> T) async -> T? {
        let id = nextID
        nextID += 1
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

    private func release(_ window: WindowHandle, _ id: Int) {
        if entries[window]?.id == id { entries[window] = nil }
    }
}
