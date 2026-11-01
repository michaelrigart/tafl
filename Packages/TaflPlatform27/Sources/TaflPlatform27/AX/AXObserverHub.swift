import ApplicationServices
import Foundation
import Synchronization

public final class AXObserverHub: @unchecked Sendable { // reason: run-loop state is touched only on the hub thread; the registration table is behind a Mutex
    public struct Event: @unchecked Sendable { // reason: AXUIElement is an immutable CF reference, read only by the handler
        public let pid: pid_t
        public let bundleID: String?
        public let notification: String
        public let element: AXUIElement
    }

    public typealias Handler = @Sendable (Event) -> Void

    public static let notifications = [
        kAXWindowCreatedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXTitleChangedNotification,
        kAXUIElementDestroyedNotification,
    ]

    final class Registration: @unchecked Sendable { // reason: observer is set before the registration is published and cleared on the hub thread
        let pid: pid_t
        let bundleID: String?
        let handler: Handler
        var observer: AXObserver?

        init(pid: pid_t, bundleID: String?, handler: @escaping Handler) {
            self.pid = pid
            self.bundleID = bundleID
            self.handler = handler
        }
    }

    private let registrations = Mutex<[pid_t: Registration]>([:])
    private let runLoop: CFRunLoop

    public init() {
        let ready = DispatchSemaphore(value: 0)
        let loop = Mutex<CFRunLoop?>(nil)
        let thread = Thread {
            loop.withLock { $0 = CFRunLoopGetCurrent() }
            RunLoop.current.add(Port(), forMode: .default)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "com.michaelrigart.tafl.ax-observers"
        thread.start()
        ready.wait()
        runLoop = loop.withLock { $0! }
    }

    deinit {
        CFRunLoopStop(runLoop)
    }

    /// Registers the notifications for one app and returns the names that failed to register.
    public func observe(pid: pid_t, bundleID: String?, handler: @escaping Handler) -> Set<String> {
        stopObserving(pid: pid)
        let registration = Registration(pid: pid, bundleID: bundleID, handler: handler)
        var observer: AXObserver?
        guard AXObserverCreate(pid, observerCallback, &observer) == .success, let observer else {
            return Set(Self.notifications)
        }
        registration.observer = observer
        let app = AXUIElementCreateApplication(pid)
        let context = Unmanaged.passUnretained(registration).toOpaque()
        var failed = Set<String>()
        for name in Self.notifications {
            let status = AXObserverAddNotification(observer, app, name as CFString, context)
            if status != .success && status != .notificationAlreadyRegistered { failed.insert(name) }
        }
        registrations.withLock { $0[pid] = registration }
        CFRunLoopAddSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
        CFRunLoopWakeUp(runLoop)
        return failed
    }

    public func stopObserving(pid: pid_t) {
        guard let registration = registrations.withLock({ $0.removeValue(forKey: pid) }) else { return }
        remove(registration)
    }

    public func stopAll() {
        let all = registrations.withLock { table in
            defer { table.removeAll() }
            return Array(table.values)
        }
        all.forEach(remove)
    }

    /// The source leaves the run loop on the hub thread, so a callback in flight finishes
    /// before the registration its context points at is released.
    private func remove(_ registration: Registration) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
            if let observer = registration.observer {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
            }
            registration.observer = nil
        }
        CFRunLoopWakeUp(runLoop)
    }
}

private let observerCallback: AXObserverCallback = { _, element, notification, context in
    guard let context else { return }
    let registration = Unmanaged<AXObserverHub.Registration>.fromOpaque(context).takeUnretainedValue()
    registration.handler(AXObserverHub.Event(
        pid: registration.pid, bundleID: registration.bundleID,
        notification: notification as String, element: element))
}
