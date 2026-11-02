import ApplicationServices
import TaflCore

/// Turns the hub's Accessibility notifications into `PlatformEvent`s. Events arrive one at a time and
/// in order; a window the registry does not know yet, and a title, are read on a task of their own so a
/// slow app never holds the rest back. No frame or title is read on the hub thread.
final class WindowEventTranslator: Sendable {
    private let registry: WindowRegistry
    private let axQueue: AXQueue
    private let events: AsyncStream<PlatformEvent>.Continuation

    init(registry: WindowRegistry, axQueue: AXQueue, events: AsyncStream<PlatformEvent>.Continuation) {
        self.registry = registry
        self.axQueue = axQueue
        self.events = events
    }

    func handle(_ event: AXObserverHub.Event) async {
        let element = AXElementBox(event.element)
        let known = await registry.knownHandle(of: element)
        switch event.notification {
        case kAXUIElementDestroyedNotification:
            guard let known else { return }
            await registry.remove(known)
            events.yield(.windowDestroyed(known))
        case kAXWindowCreatedNotification:
            spawn { if let snapshot = await $0.register(element, pid: event.pid) { $0.events.yield(.windowCreated(snapshot)) } }
        case kAXWindowMovedNotification:
            emit(known, element: element, pid: event.pid) { .windowMoved($0) }
        case kAXWindowResizedNotification:
            emit(known, element: element, pid: event.pid) { .windowResized($0) }
        case kAXTitleChangedNotification:
            guard let known else {
                spawn { if let snapshot = await $0.register(element, pid: event.pid) { $0.events.yield(.titleChanged(snapshot.handle, snapshot.title)) } }
                return
            }
            spawn { translator in
                let title = await translator.axQueue.run(pid: event.pid) { AXWindowAccess.title(element.element) ?? "" }
                translator.events.yield(.titleChanged(known, title))
            }
        default:
            return
        }
    }

    private func emit(
        _ known: WindowHandle?, element: AXElementBox, pid: pid_t, _ event: @escaping @Sendable (WindowHandle) -> PlatformEvent
    ) {
        if let known {
            events.yield(event(known))
        } else {
            spawn { translator in
                if let snapshot = await translator.register(element, pid: pid) { translator.events.yield(event(snapshot.handle)) }
            }
        }
    }

    private func spawn(_ work: @escaping @Sendable (WindowEventTranslator) async -> Void) {
        Task { await work(self) }
    }

    /// Registers a window the registry has not seen. Windows that are not standard windows or sheets
    /// are never registered, so their events stop here.
    private func register(_ element: AXElementBox, pid: pid_t) async -> WindowSnapshot? {
        let read = await axQueue.run(pid: pid) { Windows27.read(element.element, pid: pid, resolveID: true) }
        guard case .success(let window) = read, Windows27.isTracked(window.attributes) else { return nil }
        let handle = await registry.handle(for: window.element, pid: pid, windowID: window.windowID)
        let app = AppInfo27.running(pid: pid) ?? AppInfo27(pid: pid, bundleID: nil, name: "App", isHidden: false)
        return Windows27.snapshot(handle: handle, app: app, attributes: window.attributes)
    }
}
