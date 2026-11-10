import ApplicationServices
import Synchronization
import TaflCore
import Testing
@testable import TaflPlatform27

/// An app's serial queue that the test runs by hand: work runs in the order it was queued, when
/// `drain()` is called.
final class ManualQueue: Sendable {
    private let work = Mutex<[@Sendable () -> Void]>([])
    private let queued = CountWaiters()

    func enqueue(_ body: @escaping @Sendable () -> Void) {
        work.withLock { $0.append(body) }
        queued.increment()
    }

    /// Runs the queued work in order, including work queued while it runs.
    func drain() {
        while let next = work.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) { next() }
    }

    /// Waits until `count` pieces of work have been queued, drained or not.
    func waitForQueued(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
        await queued.wait(for: count, sourceLocation: sourceLocation)
    }
}

/// A registry and a translator, with the ends it delivers through, sharing the notices and the
/// events as they do in the platform. Elements are named by the pid they were made from, and a
/// registered window's exact id is that number. Work for the app's queue goes to `queue`, or runs at
/// once without one.
struct EndsHarness {
    static let pid: pid_t = 10
    let registry = WindowRegistry()
    let notices = RecordedNotices()
    let translator: WindowEventTranslator
    private var iterator: AsyncStream<PlatformEvent>.Iterator

    init(queue: ManualQueue? = nil) {
        let (stream, continuation) = AsyncStream<PlatformEvent>.makeStream()
        let afterReads: @Sendable (pid_t, @escaping @Sendable () -> Void) -> Void = if let queue {
            { _, work in queue.enqueue(work) }
        } else {
            { _, work in work() }
        }
        let reader = WindowReader27(
            readTracked: { _, _, _, _ in nil }, title: { _, _ in "" }, app: { _ in nil }, afterReads: afterReads)
        translator = WindowEventTranslator(registry: registry, reader: reader, events: continuation, notices: notices)
        iterator = stream.makeAsyncIterator()
    }

    var ends: WindowEnds { translator.ends }

    func element(_ id: pid_t) -> AXElementBox { AXElementBox(AXUIElementCreateApplication(id)) }

    /// Registers the element named `id` under the exact id `windowID`, by default its own.
    @discardableResult
    func register(_ id: pid_t, as windowID: pid_t? = nil) -> WindowHandle {
        registry.handle(
            for: element(id), pid: Self.pid,
            windowID: ResolvedWindowID(id: UInt32(windowID ?? id), by: .privateSymbol))
    }

    /// Hands the translator a notification for the element named `id`.
    func notify(_ notification: String, _ id: pid_t) {
        translator.enqueue(AXObserverHub.Event(pid: Self.pid, bundleID: nil, notification: notification, element: element(id).element))
    }

    /// The events delivered from here up to and including `last`.
    mutating func events(through last: PlatformEvent) async -> [PlatformEvent] {
        var seen: [PlatformEvent] = []
        while let event = await iterator.next() {
            seen.append(event)
            if event == last { break }
        }
        return seen
    }
}
