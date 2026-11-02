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
    /// `previous` is nil before the first read, and after the app forgot it to read the file again.
    /// While the app watches the file, a zero-length read is taken for the middle of a save (a
    /// truncate before its write) and ignored; to return to the defaults, delete the file. At
    /// the first read an empty file means the defaults.
    public static func step(previous: ConfigRead?, new: ConfigRead, hasActivationFailures: Bool) -> ConfigReloadStep {
        if previous != nil, case .text(let text) = new, text.isEmpty { return .nothing }
        guard let previous, previous == new else { return .apply }
        return hasActivationFailures ? .retryShortcuts : .nothing
    }

    /// `lastApplied` is the setting the item was last handled for, nil before the first time.
    public static func loginItem(enabled: Bool, lastApplied: Bool?, bundlePath: String) -> LoginItemStep {
        guard lastApplied != enabled else { return .unchanged }
        return bundlePath.hasPrefix("/Applications/") ? .apply : .skipNotInstalled
    }
}
