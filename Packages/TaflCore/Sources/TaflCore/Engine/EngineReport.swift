import Foundation

/// What the engine tells the app shell: the shell shows the failures and keeps the rest for
/// the menu and diagnostics.
public enum EngineReport: Equatable, Sendable {
    /// `display` is the window's display; nil when there is no window or no permission to find one.
    case failure(FailureKind, display: DisplayIdentity?)
    /// `placed` counts windows that now sit where the layout puts them.
    case layoutApplied(name: String, placed: Int, failed: Int)
    /// `moved` counts windows the rules wrote.
    case displayChangeHandled(moved: Int)
    case unobservable(bundleID: String?)
    case memory(MemoryLoad)
}
