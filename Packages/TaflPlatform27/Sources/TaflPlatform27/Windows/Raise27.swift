import ApplicationServices

/// Bringing one window to the front: raise it, then make its app frontmost, both through
/// Accessibility. `NSRunningApplication.activate` is unreliable from a background agent, so it is
/// only the fallback for an app that refuses the frontmost write.
enum Raise27 {
    enum Outcome: Equatable {
        case raised
        /// The window was raised, but the app did not accept the frontmost write.
        case raisedWithoutFrontmost
        /// The window could not be raised, so its app was not asked to come forward.
        case failed(AXError)
    }

    /// Blocks on Accessibility: call it only on the app's `AXQueue`.
    static func bringForward(raise: () -> AXError, makeFrontmost: () -> AXError) -> Outcome {
        let raised = raise()
        guard raised == .success else { return .failed(raised) }
        return makeFrontmost() == .success ? .raised : .raisedWithoutFrontmost
    }
}
