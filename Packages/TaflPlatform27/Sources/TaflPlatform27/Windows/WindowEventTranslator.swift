import ApplicationServices
import Synchronization
import TaflCore

/// Turns the hub's Accessibility notifications into `PlatformEvent`s. Each app has a lane: its events
/// are handled one at a time and in order, including the reads for a window the registry does not
/// know yet, and a slow app delays only its own lane. Nothing is read on the hub thread.
final class WindowEventTranslator: Sendable {
    private let registry: WindowRegistry
    private let reader: WindowReader27
    private let events: AsyncStream<PlatformEvent>.Continuation
    private let lanes = Mutex<[pid_t: AsyncStream<AXObserverHub.Event>.Continuation]>([:])

    init(registry: WindowRegistry, reader: WindowReader27, events: AsyncStream<PlatformEvent>.Continuation) {
        self.registry = registry
        self.reader = reader
        self.events = events
    }

    /// Never blocks: it only hands the event to its app's lane.
    func enqueue(_ event: AXObserverHub.Event) {
        lane(for: event.pid).yield(event)
    }

    /// The lane ends after the events already in it.
    func closeLane(pid: pid_t) {
        lanes.withLock { $0.removeValue(forKey: pid) }?.finish()
    }

    func closeAll() {
        let all = lanes.withLock { table in
            defer { table.removeAll() }
            return Array(table.values)
        }
        all.forEach { $0.finish() }
    }

    private func lane(for pid: pid_t) -> AsyncStream<AXObserverHub.Event>.Continuation {
        lanes.withLock { table in
            if let existing = table[pid] { return existing }
            let (stream, continuation) = AsyncStream<AXObserverHub.Event>.makeStream(bufferingPolicy: .unbounded)
            table[pid] = continuation
            Task {
                for await event in stream { await self.handle(event) }
            }
            return continuation
        }
    }

    private func handle(_ event: AXObserverHub.Event) async {
        let element = AXElementBox(event.element)
        let pid = event.pid
        let known = await registry.knownHandle(of: element)
        switch event.notification {
        case kAXUIElementDestroyedNotification:
            guard let known else { return }
            await registry.remove(known)
            events.yield(.windowDestroyed(known))
        case kAXWindowCreatedNotification:
            guard known == nil, let entry = await learn(element, pid: pid), entry.isNew else { return }
            events.yield(.windowCreated(entry.snapshot))
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

    /// Registers a window the registry has not seen. Anything that is not a standard window or sheet,
    /// and a window whose process is gone, is never registered.
    private func learn(_ element: AXElementBox, pid: pid_t) async -> WindowCatalog27.Entry? {
        guard let window = await reader.readTracked(element, pid, true), let app = reader.app(pid) else { return nil }
        let registration = await registry.register(window.element, pid: pid, windowID: window.windowID)
        let snapshot = Windows27.snapshot(handle: registration.handle, app: app, attributes: window.attributes)
        return WindowCatalog27.Entry(snapshot: snapshot, isNew: registration.isNew)
    }
}
