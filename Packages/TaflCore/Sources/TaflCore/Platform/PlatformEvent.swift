import Foundation

public enum ObservedEvent: String, Sendable {
    case created, moved, resized, titleChanged, destroyed
}

public enum PlatformEvent: Equatable, Sendable {
    /// A window's announcement. The platform announces a window only for an app whose creations it
    /// observes (a creation notification, or the catch-up of a registration that observes creations),
    /// so the engine places any window it is told about.
    case windowCreated(WindowSnapshot)
    case windowMoved(WindowHandle)
    case windowResized(WindowHandle)
    case titleChanged(WindowHandle, String)
    case windowDestroyed(WindowHandle)
    case appLaunched(pid: Int32, bundleID: String?)
    case appQuit(pid: Int32)
    case reconfigurationBegan
    case reconfigurationEnded
    case unobservable(pid: Int32, bundleID: String?, missing: Set<ObservedEvent>)
}
