import ApplicationServices
import TaflCore

/// The observers for every app: registers them, and hands their notifications to one task that
/// translates them in order.
final class WindowObservation27: Sendable {
    private let hub = AXObserverHub()
    private let axQueue: AXQueue
    private let registry: WindowRegistry
    private let events: AsyncStream<PlatformEvent>.Continuation
    private let notifications: AsyncStream<AXObserverHub.Event>.Continuation
    private let consumer: Task<Void, Never>

    init(axQueue: AXQueue, registry: WindowRegistry, events: AsyncStream<PlatformEvent>.Continuation) {
        self.axQueue = axQueue
        self.registry = registry
        self.events = events
        let (stream, continuation) = AsyncStream<AXObserverHub.Event>.makeStream(bufferingPolicy: .unbounded)
        notifications = continuation
        let translator = WindowEventTranslator(registry: registry, axQueue: axQueue, events: events)
        consumer = Task {
            for await event in stream { await translator.handle(event) }
        }
    }

    deinit {
        notifications.finish()
        consumer.cancel()
    }

    /// The app, or nil when every notification registered. Registration runs on the app's `AXQueue`.
    func observe(_ app: AppInfo27) async -> UnobservableApp? {
        let hub = hub
        let notifications = notifications
        let pid = app.pid
        let bundleID = app.bundleID
        let failed = await axQueue.run(pid: pid) {
            hub.observe(pid: pid, bundleID: bundleID) { event in notifications.yield(event) }
        }
        guard !failed.isEmpty else { return nil }
        return UnobservableApp(pid: pid, bundleID: bundleID, missing: Self.observedEvents(for: failed))
    }

    func appLaunched(_ app: AppInfo27) async {
        events.yield(.appLaunched(pid: app.pid, bundleID: app.bundleID))
        if let unobservable = await observe(app) {
            PlatformLog.windows.notice("Cannot observe \(unobservable.bundleID ?? "an app", privacy: .public)")
            events.yield(.unobservable(pid: unobservable.pid, bundleID: unobservable.bundleID, missing: unobservable.missing))
        }
    }

    func appQuit(pid: Int32) async {
        events.yield(.appQuit(pid: pid))
        let hub = hub
        await axQueue.run(pid: pid) { hub.stopObserving(pid: pid) }
        await registry.removeApp(pid: pid)
    }

    func stopAll() {
        hub.stopAll()
    }

    static func observedEvents(for notifications: Set<String>) -> Set<ObservedEvent> {
        Set(notifications.compactMap { name in
            switch name {
            case kAXWindowCreatedNotification: .created
            case kAXWindowMovedNotification: .moved
            case kAXWindowResizedNotification: .resized
            case kAXTitleChangedNotification: .titleChanged
            case kAXUIElementDestroyedNotification: .destroyed
            default: nil
            }
        })
    }
}
