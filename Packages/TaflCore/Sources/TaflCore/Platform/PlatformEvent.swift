import Foundation

public enum ObservedEvent: String, Sendable {
    case created, moved, resized, titleChanged, destroyed
}

public enum PlatformEvent: Equatable, Sendable {
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
    /// A registration the engine asked for again took: what the app still misses, empty when nothing.
    /// It comes before the announcements the registration makes, so a window announced next is judged
    /// by it.
    case observed(pid: Int32, missing: Set<ObservedEvent>)
}
