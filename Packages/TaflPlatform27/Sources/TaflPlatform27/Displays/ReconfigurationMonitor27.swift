import CoreGraphics
import Synchronization

public enum ReconfigurationPhase: Sendable, Equatable {
    case began
    case ended
}

/// Which display a callback is about, and the raw `CGDisplayChangeSummaryFlags` value.
public struct ReconfigurationDetail: Sendable, Equatable {
    public let displayID: CGDirectDisplayID
    public let flags: UInt32
}

public final class ReconfigurationMonitor27: Sendable {
    public typealias Handler = @Sendable (ReconfigurationPhase, ReconfigurationDetail) -> Void

    final class Box: Sendable {
        let handler: Handler
        init(_ handler: @escaping Handler) { self.handler = handler }
    }

    private let box = Mutex<Box?>(nil)

    public init(handler: @escaping Handler) {
        let created = Box(handler)
        box.withLock { $0 = created }
        CGDisplayRegisterReconfigurationCallback(reconfigurationCallback, Unmanaged.passUnretained(created).toOpaque())
    }

    deinit { invalidate() }

    public func invalidate() {
        guard let registered = box.withLock({ $0.take() }) else { return }
        CGDisplayRemoveReconfigurationCallback(reconfigurationCallback, Unmanaged.passUnretained(registered).toOpaque())
    }
}

private let reconfigurationCallback: CGDisplayReconfigurationCallBack = { display, flags, context in
    guard let context else { return }
    let box = Unmanaged<ReconfigurationMonitor27.Box>.fromOpaque(context).takeUnretainedValue()
    box.handler(
        flags.contains(.beginConfigurationFlag) ? .began : .ended,
        ReconfigurationDetail(displayID: display, flags: flags.rawValue))
}
