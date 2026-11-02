import Testing
@testable import TaflPlatform27

/// Ported from Rectangle v2.0.4's `EnhancedUITests`, for its `.automatic` mode, the only mode Tafl has.
private func sessionEvents(
    bundleID: String? = "com.google.Chrome",
    assistiveTechnologyOn: Bool = false,
    initial: Bool?
) -> [String] {
    var events = [String]()
    let restore = EnhancedUIPolicy.begin(
        bundleID: bundleID,
        assistiveTechnologyOn: assistiveTechnologyOn,
        read: {
            events.append("read")
            return initial
        },
        write: { events.append("write:\($0)") })
    events.append("adjust")
    EnhancedUIPolicy.end(restore: restore, write: { events.append("write:\($0)") })
    return events
}

@Test func chromiumStaysOffWhenNoAssistiveTechnologyRuns() {
    #expect(sessionEvents(initial: true) == ["read", "write:false", "adjust"])
}

@Test func otherAppsGetEnhancedUIBack() {
    #expect(sessionEvents(bundleID: "com.apple.Safari", initial: true) == ["read", "write:false", "adjust", "write:true"])
    #expect(sessionEvents(bundleID: nil, initial: true) == ["read", "write:false", "adjust", "write:true"])
}

@Test func assistiveTechnologyGetsEnhancedUIBackEvenForChromium() {
    #expect(sessionEvents(assistiveTechnologyOn: true, initial: true) == ["read", "write:false", "adjust", "write:true"])
}

@Test func enhancedUIThatWasOffOrUnreadableIsNeverWritten() {
    #expect(sessionEvents(initial: false) == ["read", "adjust"])
    #expect(sessionEvents(initial: nil) == ["read", "adjust"])
    #expect(sessionEvents(bundleID: "com.apple.Safari", initial: nil) == ["read", "adjust"])
}

@Test func chromiumFamiliesMatchByBundleIDOrItsHelperSuffix() {
    for bundleID in ["com.google.Chrome", "com.google.Chrome.canary", "com.microsoft.edgemac", "company.thebrowser.Browser", "com.openai.atlas"] {
        #expect(EnhancedUIPolicy.isKnownChromiumBrowser(bundleID: bundleID), "\(bundleID)")
    }
    for bundleID in ["com.apple.Safari", "com.google.ChromeFake", "org.mozilla.firefox"] {
        #expect(!EnhancedUIPolicy.isKnownChromiumBrowser(bundleID: bundleID), "\(bundleID)")
    }
    #expect(!EnhancedUIPolicy.isKnownChromiumBrowser(bundleID: nil))
}

@Test func restorePolicyIsRectanglesAutomaticMode() {
    #expect(!EnhancedUIPolicy.restores(bundleID: "com.google.Chrome", assistiveTechnologyOn: false))
    #expect(EnhancedUIPolicy.restores(bundleID: "com.google.Chrome", assistiveTechnologyOn: true))
    #expect(EnhancedUIPolicy.restores(bundleID: "com.apple.Safari", assistiveTechnologyOn: false))
    #expect(EnhancedUIPolicy.restores(bundleID: nil, assistiveTechnologyOn: false))
}
