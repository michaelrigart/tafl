import Foundation

/// The text Copy Diagnostics puts on the clipboard. It holds counts, states and failure
/// categories and counts only: never an app name, a window title, a bundle identifier or a path.
/// A failure string that is not one of `FailureKind.categories` is dropped.
public enum Diagnostics {
    public static let recentFailureLimit = 20

    public static func report(
        macOS: String,
        displayCount: Int,
        status: ConfigStatus,
        capabilities: [CapabilityState],
        unobservableApps: Int,
        recentFailures: [String]
    ) -> String {
        var lines = [
            "Tafl diagnostics",
            "macOS: \(macOS)",
            "Displays: \(displayCount)",
            "Config: \(describe(status))",
            "Capabilities:",
        ]
        if capabilities.isEmpty { lines.append("  none reported") }
        for capability in capabilities {
            lines.append("  \(capability.name): \(capability.isAvailable ? "available" : "unavailable")")
        }
        lines.append("Apps that can't be observed: \(unobservableApps)")
        let categories = recentFailures.filter(FailureKind.categories.contains).suffix(recentFailureLimit)
        lines.append("Recent failures: \(categories.isEmpty ? "none" : categories.joined(separator: ", "))")
        return lines.joined(separator: "\n") + "\n"
    }

    /// The error's text can quote what the file says, so only its line is kept.
    private static func describe(_ status: ConfigStatus) -> String {
        switch status {
        case .defaults: "no file, using defaults"
        case .loaded: "loaded"
        case .rejected(let error): error.line.map { "rejected at line \($0)" } ?? "rejected"
        }
    }
}
