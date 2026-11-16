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

/// Rectangle's `testKnownChromiumBrowserBundleIdentifiers`, whole.
@Test func chromiumBrowsersMatchByFamilyAndDottedSuffix() {
    let matching = [
        "com.google.Chrome", "com.google.Chrome.canary", "org.chromium.Chromium", "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta", "com.brave.Browser", "com.brave.Browser.nightly", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera", "com.operasoftware.OperaNext", "com.operasoftware.OperaDeveloper",
        "com.operasoftware.OperaNightly", "com.operasoftware.OperaGX", "com.operasoftware.OperaGXNext",
        "com.operasoftware.OperaGXDeveloper", "com.operasoftware.OperaGXNightly", "company.thebrowser.Browser",
        "company.thebrowser.dia", "ai.perplexity.comet", "com.openai.atlas",
    ]
    let notMatching: [String?] = [
        nil, "com.apple.Safari", "com.google.Chromecast", "com.google.ChromeHelper", "com.brave.BrowserHelper",
        "com.google.ChromeFake", "org.mozilla.firefox",
    ]
    for bundleID in matching { #expect(EnhancedUIPolicy.isKnownChromiumBrowser(bundleID: bundleID), "\(bundleID)") }
    for bundleID in notMatching { #expect(!EnhancedUIPolicy.isKnownChromiumBrowser(bundleID: bundleID), "\(String(describing: bundleID))") }
}

@Test func restorePolicyIsRectanglesAutomaticMode() {
    #expect(!EnhancedUIPolicy.restores(bundleID: "com.google.Chrome", assistiveTechnologyOn: false))
    #expect(EnhancedUIPolicy.restores(bundleID: "com.google.Chrome", assistiveTechnologyOn: true))
    #expect(EnhancedUIPolicy.restores(bundleID: "com.apple.Safari", assistiveTechnologyOn: false))
    #expect(EnhancedUIPolicy.restores(bundleID: nil, assistiveTechnologyOn: false))
}
