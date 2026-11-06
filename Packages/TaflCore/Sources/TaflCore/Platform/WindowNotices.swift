import Foundation

/// What the platform tells the core about a window's life, in its app's order. Each call runs in the
/// app's serial work, after every read of the app's windows already under way there, and must be
/// quick and never call back into the platform.
public protocol WindowNotices: Sendable {
    /// A window's creation is being announced: called inside the read that found the window, once
    /// the announcement is sure to be published.
    func announced(_ snapshot: WindowSnapshot)
    /// The window was destroyed. A read of it after this finds no window.
    func destroyed(_ window: WindowHandle)
    /// The app quit. A read of its windows after this finds none.
    func quit(pid: Int32)
}
