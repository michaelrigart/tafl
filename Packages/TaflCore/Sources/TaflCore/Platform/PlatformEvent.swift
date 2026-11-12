import Foundation

public enum ObservedEvent: String, Sendable {
    case created, moved, resized, titleChanged, destroyed
}

public enum PlatformEvent: Equatable, Sendable {
    /// A window's announcement. The platform announces a window only while its app's current
    /// registration observes placement (creations, moves, resizes and destructions), and only after
    /// that registration's `.observability`, so the engine places any window it is told about.
    case windowCreated(WindowSnapshot)
    case windowMoved(WindowHandle)
    case windowResized(WindowHandle)
    case titleChanged(WindowHandle, String)
    case windowDestroyed(WindowHandle)
    case appLaunched(pid: Int32, bundleID: String?)
    case appQuit(pid: Int32)
    case reconfigurationBegan
    case reconfigurationEnded
    /// The outcome of one registration of the app's observers: the events the app misses from now on,
    /// none when it is observed. Every registration publishes one, in the app's order, before any window
    /// it announces; the latest is the app's state. `retrying` says the platform registers the app again
    /// on its own (once it has finished launching, or after a launch or a query's first meeting failed),
    /// so its tries are not over.
    case observability(pid: Int32, bundleID: String?, missing: Set<ObservedEvent>, retrying: Bool)
}
