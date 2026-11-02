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
}
