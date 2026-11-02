import Testing
@testable import TaflCore

@Test func theFirstReadIsApplied() {
    #expect(ConfigReload.step(previous: nil, new: .missing, hasActivationFailures: false) == .apply)
}

@Test func aChangedReadIsApplied() {
    #expect(ConfigReload.step(previous: .text("gap = 1"), new: .text("gap = 2"), hasActivationFailures: false) == .apply)
    #expect(ConfigReload.step(previous: .missing, new: .unreadable("x"), hasActivationFailures: true) == .apply)
}

@Test func anUnchangedReadDoesNothing() {
    #expect(ConfigReload.step(previous: .text("gap = 1"), new: .text("gap = 1"), hasActivationFailures: false) == .nothing)
    #expect(ConfigReload.step(previous: .missing, new: .missing, hasActivationFailures: false) == .nothing)
}

@Test func anUnchangedReadRetriesShortcutsThatFailed() {
    #expect(ConfigReload.step(previous: .text("gap = 1"), new: .text("gap = 1"), hasActivationFailures: true) == .retryShortcuts)
}

@Test func theLoginItemIsAppliedOnceAndWhenItChanges() {
    let path = "/Applications/Tafl.app"
    #expect(ConfigReload.loginItem(enabled: true, lastApplied: nil, bundlePath: path) == .apply)
    #expect(ConfigReload.loginItem(enabled: true, lastApplied: true, bundlePath: path) == .unchanged)
    #expect(ConfigReload.loginItem(enabled: false, lastApplied: true, bundlePath: path) == .apply)
}

@Test func aCopyOutsideApplicationsNeverTouchesTheLoginItem() {
    let path = "/Users/m/Code/tafl/build/Build/Products/Debug/Tafl.app"
    #expect(ConfigReload.loginItem(enabled: true, lastApplied: nil, bundlePath: path) == .skipNotInstalled)
    #expect(ConfigReload.loginItem(enabled: true, lastApplied: true, bundlePath: path) == .unchanged)
    #expect(ConfigReload.loginItem(enabled: true, lastApplied: nil, bundlePath: "/Applications2/Tafl.app") == .skipNotInstalled)
}
