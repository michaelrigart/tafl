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

    /// What the two checks answered. `call` is nil when the process already reported itself trusted.
    public struct Observation: Sendable, Equatable {
        public let reported: Bool
        public let call: AXError?

        /// The one trust rule. macOS 27.2 can keep answering `AXIsProcessTrusted()` false in a process
        /// that was running when the grant was switched on, so a real call macOS answers counts too.
        /// A refusal is not a grant, and a timeout is unknown, which counts as not trusted.
        public var isTrusted: Bool {
            guard !reported else { return true }
            guard let call else { return false }
            return call != .apiDisabled && call != .cannotComplete
        }

        /// Both answers for the log, e.g. `reported=false call=apiDisabled`.
        public var summary: String {
            "reported=\(reported) call=\(call.map(Self.name(of:)) ?? "not needed")"
        }

        private static func name(of error: AXError) -> String {
            switch error {
            case .success: "success"
            case .noValue: "noValue"
            case .apiDisabled: "apiDisabled"
            case .cannotComplete: "cannotComplete"
            case .attributeUnsupported: "attributeUnsupported"
            case .failure: "failure"
            default: "\(error.rawValue)"
            }
        }
    }

    private let reported: @Sendable () -> Bool
    private let call: @Sendable () -> AXError

    public var isTrusted: Bool { observe().isTrusted }

    public func observe() -> Observation { Self.observe(reported: reported, call: call) }

    private static func observe(reported: () -> Bool, call: () -> AXError) -> Observation {
        if reported() { return Observation(reported: true, call: nil) }
        return Observation(reported: false, call: call())
    }

    public convenience init() {
        self.init(
            center: DistributedNotificationCenter.default(),
            name: Notification.Name("com.apple.accessibility.api"),
            reported: { AXIsProcessTrusted() },
            call: Self.focusedApplicationCall)
    }

    private static let callTimeout: Float = 0.25

    /// Asks the system-wide element for the focused application, which only a trusted process gets answered.
    private static func focusedApplicationCall() -> AXError {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, callTimeout)
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &value)
    }

    /// The notification can arrive before the change takes effect, so each one is read twice: at once
    /// and on the next main run-loop turn. A value is emitted only when it differs from the last one seen.
    init(
        center: NotificationCenter, name: Notification.Name,
        reported: @escaping @Sendable () -> Bool, call: @escaping @Sendable () -> AXError
    ) {
        self.center = center
        self.reported = reported
        self.call = call
        let read: @Sendable () -> Bool = { Self.observe(reported: reported, call: call).isTrusted }
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
