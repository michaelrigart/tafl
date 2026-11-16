/// Rectangle v2.0.4's `.automatic` Enhanced UI mode (`AccessibilityElement.swift`): Enhanced UI is
/// switched off for the app whenever it is on, and put back afterwards unless the app is a
/// Chromium browser and no assistive technology (VoiceOver, Switch Control) is running.
///
/// Rectangle's other modes and its switch-off-on-activation are not ported: Tafl has one mode.
enum EnhancedUIPolicy {
    private static let chromiumBundleIDFamilies = [
        "com.google.Chrome",
        "org.chromium.Chromium",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "com.operasoftware.OperaNext",
        "com.operasoftware.OperaDeveloper",
        "com.operasoftware.OperaNightly",
        "com.operasoftware.OperaGX",
        "com.operasoftware.OperaGXNext",
        "com.operasoftware.OperaGXDeveloper",
        "com.operasoftware.OperaGXNightly",
        "company.thebrowser.Browser",
        "company.thebrowser.dia",
        "ai.perplexity.comet",
        "com.openai.atlas",
    ]

    static func isKnownChromiumBrowser(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return chromiumBundleIDFamilies.contains { bundleID == $0 || bundleID.hasPrefix("\($0).") }
    }

    /// Whether Enhanced UI is turned back on at the end of a session that turned it off.
    static func restores(bundleID: String?, assistiveTechnologyOn: Bool) -> Bool {
        assistiveTechnologyOn || !isKnownChromiumBrowser(bundleID: bundleID)
    }

    /// Reads Enhanced UI and switches it off when it is on. The result is whether `end` must switch
    /// it back on.
    static func begin(
        bundleID: String?,
        assistiveTechnologyOn: Bool,
        read: () -> Bool?,
        write: (Bool) -> Void
    ) -> Bool {
        let wasOn = read() == true
        if wasOn { write(false) }
        return wasOn && restores(bundleID: bundleID, assistiveTechnologyOn: assistiveTechnologyOn)
    }

    static func end(restore: Bool, write: (Bool) -> Void) {
        if restore { write(true) }
    }
}
