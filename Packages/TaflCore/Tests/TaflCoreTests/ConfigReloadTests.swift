import Testing
@testable import TaflCore

@Test func theFirstReadIsApplied() {
    #expect(ConfigReload.step(previous: nil, new: .missing, hasActivationFailures: false) == .apply)
}

@Test func anEmptyFileAtTheFirstReadMeansTheDefaults() {
    #expect(ConfigReload.step(previous: nil, new: .text(""), hasActivationFailures: false) == .apply)
}

@Test func anEmptyReadWhileWatchingIsASaveInProgress() {
    #expect(ConfigReload.step(previous: .text("gap = 1"), new: .text(""), hasActivationFailures: false) == .nothing)
    #expect(ConfigReload.step(previous: .missing, new: .text(""), hasActivationFailures: true) == .nothing)
    #expect(ConfigReload.step(previous: .unreadable("x"), new: .text(""), hasActivationFailures: false) == .nothing)
}

@Test func aFileTruncatedAndWrittenShorterIsAppliedOnceWritten() {
    let long = ConfigRead.text("gap = 10\nstep = 5")
    // The truncate is a save in progress, so the long read stays the last one; the write that
    // follows is shorter than the file was and is applied, not taken for another truncate.
    #expect(ConfigReload.step(previous: long, new: .text(""), hasActivationFailures: false) == .nothing)
    #expect(ConfigReload.step(previous: long, new: .text("g"), hasActivationFailures: false) == .apply)
}

@Test func anInputSourceChangeDuringASaveParsesTheLastReadAgain() {
    let last = ConfigRead.text("gap = 1")
    // The file is empty in the middle of a save: the read is ignored, so the last read stands
    // and is what the new layout table parses, not the empty file.
    #expect(ConfigReload.step(previous: last, new: .text(""), hasActivationFailures: false) == .nothing)
    #expect(ConfigReload.reparse(lastRead: last) == .parse(last))
}

@Test func anInputSourceChangeBeforeAnyReadReadsTheFile() {
    #expect(ConfigReload.reparse(lastRead: nil) == .read)
}

@Test func aMissingFileWhileWatchingIsStillTheDefaults() {
    #expect(ConfigReload.step(previous: .text("gap = 1"), new: .missing, hasActivationFailures: false) == .apply)
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
