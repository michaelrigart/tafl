import ApplicationServices
import Synchronization
import TaflCore

/// Turns the hub's Accessibility notifications into `PlatformEvent`s. Each app has a lane: its events
/// are handled one at a time and in order, including the reads for a window the registry does not
/// know yet, and a slow app delays only its own lane. Nothing is read on the hub thread. A window's
/// announcement reaches the notices inside the read that found it, and its end on its app's queue,
/// after the reads already there, through `WindowEnds`.
final class WindowEventTranslator: Sendable {
    private let registry: WindowRegistry
    private let reader: WindowReader27
    private let events: AsyncStream<PlatformEvent>.Continuation
    private let notices: any WindowNotices
    let ends: WindowEnds
    private struct Lanes {
        var open: [pid_t: AsyncStream<AXObserverHub.Event>.Continuation] = [:]
        /// Apps whose lane was closed: a late callback must not start a lane that nothing would end.
        var closed = Set<pid_t>()
    }

    private let lanes = Mutex(Lanes())

    var laneCount: Int { lanes.withLock { $0.open.count } }

    init(
        registry: WindowRegistry,
        reader: WindowReader27,
        events: AsyncStream<PlatformEvent>.Continuation,
        notices: any WindowNotices
    ) {
        self.registry = registry
        self.reader = reader
        self.events = events
        self.notices = notices
        ends = WindowEnds(registry: registry, events: events, notices: notices, afterReads: reader.afterReads)
    }

    /// Never blocks: it only hands the event to its app's lane.
    func enqueue(_ event: AXObserverHub.Event) {
        lane(for: event.pid)?.yield(event)
    }

    /// The lane ends after the events already in it, and the app gets none until `reopen`.
    func closeLane(pid: pid_t) {
        let lane = lanes.withLock { lanes -> AsyncStream<AXObserverHub.Event>.Continuation? in
            lanes.closed.insert(pid)
            return lanes.open.removeValue(forKey: pid)
        }
        lane?.finish()
    }

    /// The pid belongs to a new registration: its events are wanted again.
    func reopen(pid: pid_t) {
        lanes.withLock { _ = $0.closed.remove(pid) }
    }

    func closeAll() {
        let all = lanes.withLock { lanes in
            defer { lanes.open.removeAll() }
            return Array(lanes.open.values)
        }
        all.forEach { $0.finish() }
    }

    private func lane(for pid: pid_t) -> AsyncStream<AXObserverHub.Event>.Continuation? {
        lanes.withLock { lanes in
            if let existing = lanes.open[pid] { return existing }
            guard !lanes.closed.contains(pid) else { return nil }
            let (stream, continuation) = AsyncStream<AXObserverHub.Event>.makeStream(bufferingPolicy: .unbounded)
            lanes.open[pid] = continuation
            Task {
                for await event in stream { await self.handle(event) }
            }
            return continuation
        }
    }

    private func handle(_ event: AXObserverHub.Event) async {
        let element = AXElementBox(event.element)
        let pid = event.pid
        let known = registry.knownHandle(of: element)
        switch event.notification {
        case kAXUIElementDestroyedNotification:
            guard let known else { return }
            ends.end(known, element)
        case kAXWindowCreatedNotification:
            // Announced once, whoever registered the window first: a query registers but never announces.
            _ = await learn(element, pid: pid, resolveID: known == nil, announcing: true)
        case kAXWindowMovedNotification:
            if let handle = await handleOf(known, element, pid) { events.yield(.windowMoved(handle)) }
        case kAXWindowResizedNotification:
            if let handle = await handleOf(known, element, pid) { events.yield(.windowResized(handle)) }
        case kAXTitleChangedNotification:
            if let known {
                events.yield(.titleChanged(known, await reader.title(element, pid)))
            } else if let entry = await learn(element, pid: pid) {
                events.yield(.titleChanged(entry.snapshot.handle, entry.snapshot.title))
            }
        default:
            return
        }
    }

    private func handleOf(_ known: WindowHandle?, _ element: AXElementBox, _ pid: pid_t) async -> WindowHandle? {
        if let known { return known }
        return await learn(element, pid: pid)?.snapshot.handle
    }

    /// Reads a window and registers it if the registry has not seen it, inside the read. Anything
    /// that is not a standard window or sheet, and a window whose process is gone, is never
    /// registered. `announcing` announces the window's creation in the same step, unless it was.
    /// The owner hears of this read only through that announcement: a move or resize of an unregistered
    /// element, and an announcement already made or refused, never reach it.
    private func learn(
        _ element: AXElementBox,
        pid: pid_t,
        resolveID: Bool = true,
        announcing: Bool = false
    ) async -> WindowCatalog27.Entry? {
        guard let app = reader.app(pid) else { return nil }
        let registry = registry
        let events = events
        let notices = notices
        return await reader.readTracked(element, pid, resolveID) { window in
            let registration = registry.register(window.element, pid: pid, windowID: window.windowID)
            let snapshot = Windows27.snapshot(handle: registration.handle, app: app, attributes: window.attributes)
            if announcing {
                _ = registry.announce(snapshot) { event in
                    notices.announced(snapshot)
                    events.yield(event)
                    return true
                }
            }
            return WindowCatalog27.Entry(snapshot: snapshot, element: window.element, isNew: registration.isNew)
        }
    }
}
