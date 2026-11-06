import ApplicationServices
import TaflCore
@testable import TaflPlatform27

/// A registry, the ends a snapshot delivers through, and a translator, sharing the notices and the
/// events as they do in the platform. Elements are named by the pid they were made from, and a
/// registered window's exact id is that number. Work for an app's queue runs at once.
struct EndsHarness {
    static let pid: pid_t = 10
    let registry = WindowRegistry()
    let notices = RecordedNotices()
    let ends: WindowEnds
    let translator: WindowEventTranslator
    private var iterator: AsyncStream<PlatformEvent>.Iterator

    init() {
        let (stream, continuation) = AsyncStream<PlatformEvent>.makeStream()
        let atOnce: @Sendable (pid_t, @escaping @Sendable () -> Void) -> Void = { _, work in work() }
        ends = WindowEnds(registry: registry, events: continuation, notices: notices, afterReads: atOnce)
        let reader = WindowReader27(
            readTracked: { _, _, _, _ in nil }, title: { _, _ in "" }, app: { _ in nil }, afterReads: atOnce)
        translator = WindowEventTranslator(registry: registry, reader: reader, events: continuation, notices: notices)
        iterator = stream.makeAsyncIterator()
    }

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

    /// Waits until the notices hold `count` entries, for up to 2 s of wall-clock time.
    func waitForNotices(_ count: Int) async -> Bool {
        let begun = ContinuousClock.now
        while notices.all.count < count {
            if begun.duration(to: .now) > .seconds(2) { return false }
            await Task.yield()
        }
        return true
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
