import ApplicationServices
import Dispatch
import Foundation
import Synchronization

public final class Permission27: @unchecked Sendable { // reason: `observer` is set once in init and read only in deinit
    private final class LastValue: Sendable {
        let value: Mutex<Bool>
        init(_ value: Bool) { self.value = Mutex(value) }

        /// True when `new` differs from the last value seen.
        func changed(to new: Bool) -> Bool {
            value.withLock { last in
                defer { last = new }
                return last != new
            }
        }
    }

    private let center: NotificationCenter
    private let observer: NSObjectProtocol
    private let continuation: AsyncStream<Bool>.Continuation
    public let changes: AsyncStream<Bool>

    private let read: @Sendable () -> Bool

    /// The one trust rule: `AXIsProcessTrusted()` alone. A real Accessibility call is no substitute:
    /// macOS still answers one in a process that was trusted and then switched off.
    public var isTrusted: Bool { read() }

    public convenience init() {
        self.init(
            center: DistributedNotificationCenter.default(),
            name: Notification.Name("com.apple.accessibility.api"),
            read: { AXIsProcessTrusted() })
    }

    /// The notification can arrive before the change takes effect, so each one is read twice: at once
    /// and on the next main run-loop turn. A value is emitted only when it differs from the last one seen.
    init(center: NotificationCenter, name: Notification.Name, read: @escaping @Sendable () -> Bool) {
        self.center = center
        self.read = read
        let last = LastValue(read())
        let (stream, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .unbounded)
        changes = stream
        self.continuation = continuation
        let emitIfChanged: @Sendable () -> Void = {
            let value = read()
            if last.changed(to: value) { continuation.yield(value) }
        }
        observer = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            emitIfChanged()
            DispatchQueue.main.async { emitIfChanged() }
        }
    }

    deinit {
        center.removeObserver(observer)
        continuation.finish()
    }
}
