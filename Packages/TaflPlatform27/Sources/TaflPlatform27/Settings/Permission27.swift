import ApplicationServices
import Dispatch
import Foundation
import Synchronization

/// Tafl's Accessibility grant, as one value that the checks keep up to date.
///
/// A running process's own answer is cached: in tccd's log, `TCCAccessPreflight` never changed from its
/// first value in an app process, and `AXIsProcessTrusted()` refilled its cache on the change
/// notification but twice cached the old value for good while System Settings was still writing the
/// change. A fresh process reads it right, so each check asks a short-lived child copy of Tafl.
/// Readers get the current value and never spawn a check.
public final class Permission27: @unchecked Sendable { // reason: `observer` is set once in init and read only in deinit
    private final class Current: Sendable {
        private let value: Mutex<Bool>
        init(_ value: Bool) { self.value = Mutex(value) }

        var get: Bool { value.withLock { $0 } }

        /// True when `new` differs from the value held.
        func set(_ new: Bool) -> Bool {
            value.withLock { current in
                defer { current = new }
                return current != new
            }
        }
    }

    /// The argument that makes a Tafl process answer the check with its exit status and nothing else.
    public static let checkArgument = "-TaflCheckAccessibility"

    /// Delays of the later checks after each notification.
    static let laterReads: [Duration] = [.milliseconds(500), .seconds(2)]

    private let center: NotificationCenter
    private let observer: NSObjectProtocol
    private let requests: AsyncStream<Void>.Continuation
    private let current: Current
    public let changes: AsyncStream<Bool>

    /// The grant as last checked. It never runs a check.
    public var isTrusted: Bool { current.get }

    public convenience init() {
        let check: @Sendable () async -> Bool?
        if let executable = Bundle.main.executableURL {
            let child = ChildExitStatus(executable: executable, arguments: [Self.checkArgument], timeout: 1)
            check = { await child.run() }
        } else {
            check = { nil }
        }
        self.init(
            center: DistributedNotificationCenter.default(),
            name: Notification.Name("com.apple.accessibility.api"),
            initial: { AXIsProcessTrusted() },
            check: check,
            fallback: { AXIsProcessTrusted() })
    }

    /// The notification can arrive before the change takes effect, so each one asks for a check at once
    /// and again 0.5 s and 2 s later (`after` runs the later ones). Checks run one at a time, in the
    /// order asked, so a late answer never overwrites a later one; requests that arrive while a check
    /// runs coalesce into one more check after it. A result that differs from the value held replaces
    /// it and is emitted. A check that answers nil (it did not start, timed out or ended oddly) is
    /// replaced by `fallback`, the process's own answer, so a revoke is not lost when the child cannot
    /// run. `initial` reads the first value, which a fresh process gets right.
    init(
        center: NotificationCenter, name: Notification.Name, initial: @Sendable () -> Bool,
        check: @escaping @Sendable () async -> Bool?,
        fallback: @escaping @Sendable () -> Bool,
        after: @escaping @Sendable (Duration, @escaping @Sendable () -> Void) -> Void = Permission27.afterOnMain
    ) {
        self.center = center
        let current = Current(initial())
        self.current = current
        let (stream, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .unbounded)
        changes = stream
        let (checkRequests, requests) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.requests = requests
        Task {
            for await _ in checkRequests {
                let result = await check() ?? fallback()
                if current.set(result) { continuation.yield(result) }
            }
            continuation.finish()
        }
        observer = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            requests.yield()
            for delay in Permission27.laterReads { after(delay) { requests.yield() } }
        }
    }

    private static func afterOnMain(_ delay: Duration, _ body: @escaping @Sendable () -> Void) {
        let (seconds, attoseconds) = delay.components
        let nanoseconds = Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000)
        DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(nanoseconds), execute: body)
    }

    deinit {
        center.removeObserver(observer)
        requests.finish()
    }
}
