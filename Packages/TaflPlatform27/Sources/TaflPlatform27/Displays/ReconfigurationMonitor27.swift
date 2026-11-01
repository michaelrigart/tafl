import CoreGraphics
import Synchronization

public enum ReconfigurationPhase: Sendable, Equatable {
    case began
    case ended
}

public final class ReconfigurationMonitor27: Sendable {
    final class Box: Sendable {
        let handler: @Sendable (ReconfigurationPhase) -> Void
        init(_ handler: @escaping @Sendable (ReconfigurationPhase) -> Void) { self.handler = handler }
    }

    private let box = Mutex<Box?>(nil)

    public init(handler: @escaping @Sendable (ReconfigurationPhase) -> Void) {
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

private let reconfigurationCallback: CGDisplayReconfigurationCallBack = { _, flags, context in
    guard let context else { return }
    let box = Unmanaged<ReconfigurationMonitor27.Box>.fromOpaque(context).takeUnretainedValue()
    box.handler(flags.contains(.beginConfigurationFlag) ? .began : .ended)
}
