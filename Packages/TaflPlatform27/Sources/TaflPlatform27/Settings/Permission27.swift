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

    /// Delays of the later reads after each notification.
    static let laterReads: [Duration] = [.milliseconds(500), .seconds(2)]

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

    /// The notification can arrive before the change takes effect, so each one is read at once, on the
    /// next main run-loop turn, and 0.5 s and 2 s later (`after` runs the later reads). A value is
    /// emitted only when it differs from the last one seen.
    init(
        center: NotificationCenter, name: Notification.Name, read: @escaping @Sendable () -> Bool,
        after: @escaping @Sendable (Duration, @escaping @Sendable () -> Void) -> Void = Permission27.afterOnMain
    ) {
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
            for delay in Permission27.laterReads { after(delay) { emitIfChanged() } }
        }
    }

    private static func afterOnMain(_ delay: Duration, _ body: @escaping @Sendable () -> Void) {
        let (seconds, attoseconds) = delay.components
        let nanoseconds = Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000)
        DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(nanoseconds), execute: body)
    }

    deinit {
        center.removeObserver(observer)
        continuation.finish()
    }
}
