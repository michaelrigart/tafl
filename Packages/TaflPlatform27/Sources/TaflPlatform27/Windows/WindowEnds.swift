import ApplicationServices
import TaflCore

/// Ends a window that is gone: takes its registration out of the registry and, only when that took
/// it out, tells the core. The notices hear of the end on the app's queue, after the reads already
/// there, and the `.windowDestroyed` event follows. The translator ends a window on its destruction
/// notification, and a snapshot on finding its element invalid: whichever withdraws the
/// registration delivers the end, so it is delivered once.
struct WindowEnds: Sendable {
    let registry: WindowRegistry
    let events: AsyncStream<PlatformEvent>.Continuation
    let notices: any WindowNotices
    /// Runs `work` on the app's queue, after the reads already there, without waiting for it.
    let afterReads: @Sendable (_ pid: pid_t, _ work: @escaping @Sendable () -> Void) -> Void

    /// Ends the window registered as `handle` for `element`. A pair no longer registered ends nothing:
    /// another path ended the window, or a new element was registered for the handle meanwhile, and
    /// that registration stays and is not announced as destroyed.
    func end(_ handle: WindowHandle, _ element: AXElementBox) {
        guard registry.withdraw([(handle, element)]) == [handle] else { return }
        let notices = notices
        afterReads(handle.pid) { notices.destroyed(handle) }
        events.yield(.windowDestroyed(handle))
    }
}
