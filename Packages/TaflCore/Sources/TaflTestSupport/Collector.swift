import Synchronization
import Testing

/// Collects what a stream sends, as it arrives, so a test reads it with a bound: the next element
/// in order (`next`), or everything sent up to now (`drain`).
public final class Collector<Element: Sendable & Equatable>: Sendable {
    private struct State {
        var collected: [Element] = []
        /// How many of `collected` `next()` has returned.
        var taken = 0
        /// The markers drains are waiting for, and the ones that have arrived.
        var pendingMarkers: [Element] = []
        var arrivedMarkers: [Element] = []
        var drains = 0
    }

    private final class Storage: Sendable {
        let state = Mutex(State())
    }

    private let storage: Storage
    private let reader: Task<Void, Never>
    private let makeMarker: @Sendable (Int) -> Element

    /// `marker` makes the element each drain sends to find where "up to now" ends; each drain asks
    /// for one with a number of its own, so a drain never matches an earlier drain's marker.
    public init(_ stream: AsyncStream<Element>, marker: @escaping @Sendable (Int) -> Element) {
        let storage = Storage()
        self.storage = storage
        makeMarker = marker
        reader = Task {
            for await element in stream {
                storage.state.withLock { state in
                    if let index = state.pendingMarkers.firstIndex(of: element) {
                        state.pendingMarkers.remove(at: index)
                        state.arrivedMarkers.append(element)
                    } else {
                        state.collected.append(element)
                    }
                }
            }
        }
    }

    deinit { reader.cancel() }

    /// Everything collected so far, without the drains' markers.
    public var all: [Element] { storage.state.withLock { $0.collected } }

    /// The next element that `next()` has not returned yet, waiting for it up to `timeout`; nil,
    /// with an issue, when none arrives.
    public func next(
        timeout: Duration = defaultWaitBound,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Element? {
        let storage = storage
        let arrived = await waitUntil("the next element of a stream", timeout: timeout, sourceLocation: sourceLocation) {
            storage.state.withLock { $0.taken < $0.collected.count }
        }
        guard arrived else { return nil }
        return storage.state.withLock { state in
            defer { state.taken += 1 }
            return state.collected[state.taken]
        }
    }

    /// Waits until everything sent before this call has been collected, and returns all that has
    /// been: `send` puts this drain's marker on the stream, and elements keep their order, so once
    /// the marker arrives nothing sent before it is still on its way.
    @discardableResult
    public func drain(
        through send: (Element) async -> Void,
        timeout: Duration = defaultWaitBound,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> [Element] {
        let storage = storage
        let marker = storage.state.withLock { state in
            state.drains += 1
            let marker = makeMarker(state.drains)
            state.pendingMarkers.append(marker)
            return marker
        }
        await send(marker)
        await waitUntil("everything sent before a drain to be collected", timeout: timeout, sourceLocation: sourceLocation) {
            storage.state.withLock { $0.arrivedMarkers.contains(marker) }
        }
        return all
    }
}
