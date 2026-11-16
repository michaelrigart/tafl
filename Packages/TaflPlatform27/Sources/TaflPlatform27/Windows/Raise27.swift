import AppKit
import ApplicationServices

/// Bringing one window to the front: raise it, then make its app frontmost, both through
/// Accessibility. `NSRunningApplication.activate` is unreliable from a background agent (activation
/// is cooperative), so it is only a best-effort fallback for an app that refuses the frontmost
/// write. Public so the Debug probe runs the sequence the platform ships.
public enum Raise27 {
    public enum Outcome: Equatable, Sendable {
        case raised
        /// The window was raised, but the app did not accept the frontmost write.
        case raisedWithoutFrontmost
        /// The window could not be raised, so its app was not asked to come forward.
        case failed(AXError)
        /// `admit` refused a step, and no step after it was made.
        case stopped
    }

    /// Blocks on Accessibility: call it only on the app's `AXQueue`. `admit` is asked immediately
    /// before the raise and again before the frontmost write.
    public static func bringForward(admit: () -> Bool, raise: () -> AXError, makeFrontmost: () -> AXError) -> Outcome {
        guard admit() else { return .stopped }
        let raised = raise()
        guard raised == .success else { return .failed(raised) }
        guard admit() else { return .stopped }
        return makeFrontmost() == .success ? .raised : .raisedWithoutFrontmost
    }

    /// The fallback for `.raisedWithoutFrontmost`, asked on the main actor immediately before it
    /// activates the app. False when `admit` refused, and the app was left alone.
    @MainActor
    public static func activate(pid: pid_t, admit: () -> Bool) -> Bool {
        guard admit() else { return false }
        _ = NSRunningApplication(processIdentifier: pid)?.activate()
        return true
    }
}
