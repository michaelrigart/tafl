import ApplicationServices
import TaflCore

/// Ends a window that is gone, in one block on the app's queue after the reads already there: it takes
/// the window's registration out of the registry and, only when that took it out, tells the notices and
/// yields `.windowDestroyed`. Every registration of a window is made on that queue too, so none for the
/// same id lands between the withdraw and the notice: one made before the block replaces the dead
/// registration and the block ends nothing, one made after it starts fresh. The translator ends a
/// window on its destruction notification, and a snapshot on finding its element invalid: whichever
/// block withdraws the registration delivers the end, so it is delivered once.
struct WindowEnds: Sendable {
    let registry: WindowRegistry
    let events: AsyncStream<PlatformEvent>.Continuation
    let notices: any WindowNotices
    /// Runs `work` on the app's queue, after the reads already there, without waiting for it.
    let afterReads: @Sendable (_ pid: pid_t, _ work: @escaping @Sendable () -> Void) -> Void

    /// Ends the window registered as `handle` for `element`. A pair no longer registered when the block
    /// runs ends nothing: another path ended the window, or a new element was registered for the handle
    /// first, and that registration stays and is not announced as destroyed.
    func end(_ handle: WindowHandle, _ element: AXElementBox) {
        let registry = registry
        let notices = notices
        let events = events
        afterReads(handle.pid) {
            guard registry.withdraw([(handle, element)]) == [handle] else { return }
            notices.destroyed(handle)
            events.yield(.windowDestroyed(handle))
        }
    }
}
