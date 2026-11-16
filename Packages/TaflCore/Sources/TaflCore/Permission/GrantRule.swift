/// What the app does when it reads the Accessibility grant. A grant that arrives in a process that ran
/// without it needs a fresh process, because observing started right after such a grant can fail for
/// every app. The app executes each action and reports whether a relaunch could start.
public struct GrantRule: Sendable {
    public enum Action: Equatable, Sendable {
        case nothing
        case showOnboarding
        case relaunch
        case startEngine
        case restartObserving
    }

    private var ranWithoutGrant: Bool
    private var relaunching = false
    private var relaunchFailed = false

    public init(ranWithoutGrant: Bool = false) {
        self.ranWithoutGrant = ranWithoutGrant
    }

    /// The action for a new reading. A reading made while a relaunch is under way changes nothing: the
    /// new copy reads the grant itself.
    public mutating func read(granted: Bool, engineStarted: Bool) -> Action {
        guard !relaunching else { return .nothing }
        guard granted else {
            ranWithoutGrant = true
            return .showOnboarding
        }
        if ranWithoutGrant, !relaunchFailed {
            relaunching = true
            return .relaunch
        }
        return continueHere(engineStarted: engineStarted)
    }

    /// The outcome of a `.relaunch`. A relaunch that could not start is never tried again in this
    /// process: the grant is used here instead.
    public mutating func relaunchAttempted(started: Bool, engineStarted: Bool) -> Action {
        guard !started else { return .nothing }
        relaunching = false
        relaunchFailed = true
        return continueHere(engineStarted: engineStarted)
    }

    private mutating func continueHere(engineStarted: Bool) -> Action {
        let hadRunWithoutGrant = ranWithoutGrant
        ranWithoutGrant = false
        if !engineStarted { return .startEngine }
        return hadRunWithoutGrant ? .restartObserving : .nothing
    }
}
