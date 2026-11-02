import Foundation

public enum ConfigReloadStep: Equatable, Sendable {
    /// Parse the read and apply it everywhere.
    case apply
    /// The file is as before; only the shortcuts that failed to register are tried again.
    case retryShortcuts
    case nothing
}

public enum LoginItemStep: Equatable, Sendable {
    case apply
    case unchanged
    /// A copy that is not installed must not register itself to start at login.
    case skipNotInstalled
}

public enum ConfigReload {
    public static func step(previous: ConfigRead?, new: ConfigRead, hasActivationFailures: Bool) -> ConfigReloadStep {
        guard let previous, previous == new else { return .apply }
        return hasActivationFailures ? .retryShortcuts : .nothing
    }

    /// `lastApplied` is the setting the item was last handled for, nil before the first time.
    public static func loginItem(enabled: Bool, lastApplied: Bool?, bundlePath: String) -> LoginItemStep {
        guard lastApplied != enabled else { return .unchanged }
        return bundlePath.hasPrefix("/Applications/") ? .apply : .skipNotInstalled
    }
}
