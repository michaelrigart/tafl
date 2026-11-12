import Testing
@testable import TaflCore

struct GrantRuleTests {
    @Test func aStartWithTheGrantStartsTheEngine() {
        var rule = GrantRule()
        #expect(rule.read(granted: true, engineStarted: false) == .startEngine)
        #expect(rule.read(granted: true, engineStarted: true) == .nothing)
    }

    @Test func aStartWithoutTheGrantShowsTheOnboarding() {
        var rule = GrantRule()
        #expect(rule.read(granted: false, engineStarted: false) == .showOnboarding)
    }

    @Test func theFirstGrantInAProcessThatStartedWithoutItRelaunches() {
        var rule = GrantRule()
        _ = rule.read(granted: false, engineStarted: false)
        #expect(rule.read(granted: true, engineStarted: false) == .relaunch)
    }

    @Test func aRevokeThenARegrantRelaunches() {
        var rule = GrantRule()
        _ = rule.read(granted: true, engineStarted: false)
        #expect(rule.read(granted: false, engineStarted: true) == .showOnboarding)
        #expect(rule.read(granted: true, engineStarted: true) == .relaunch)
    }

    @Test func anyReadingWhileARelaunchIsUnderWayDoesNothing() {
        var rule = GrantRule()
        _ = rule.read(granted: false, engineStarted: false)
        _ = rule.read(granted: true, engineStarted: false)
        #expect(rule.read(granted: true, engineStarted: false) == .nothing)
        #expect(rule.read(granted: false, engineStarted: false) == .nothing)
        #expect(rule.read(granted: true, engineStarted: true) == .nothing)
        #expect(rule.relaunchAttempted(started: true, engineStarted: false) == .nothing)
        #expect(rule.read(granted: true, engineStarted: false) == .nothing)
    }

    @Test func aRelaunchThatCouldNotStartStartsTheEngineHere() {
        var rule = GrantRule()
        _ = rule.read(granted: false, engineStarted: false)
        #expect(rule.read(granted: true, engineStarted: false) == .relaunch)
        #expect(rule.relaunchAttempted(started: false, engineStarted: false) == .startEngine)
    }

    @Test func aRelaunchThatCouldNotStartRestartsObservingWhenTheEngineRuns() {
        var rule = GrantRule()
        _ = rule.read(granted: true, engineStarted: false)
        _ = rule.read(granted: false, engineStarted: true)
        #expect(rule.read(granted: true, engineStarted: true) == .relaunch)
        #expect(rule.relaunchAttempted(started: false, engineStarted: true) == .restartObserving)
    }

    @Test func afterAFailedRelaunchALaterReadingWithTheGrantDoesNothing() {
        var rule = GrantRule()
        _ = rule.read(granted: false, engineStarted: false)
        _ = rule.read(granted: true, engineStarted: false)
        _ = rule.relaunchAttempted(started: false, engineStarted: false)
        #expect(rule.read(granted: true, engineStarted: true) == .nothing)
    }

    @Test func aFailedRelaunchIsNeverRetriedAfterARevokeAndRegrant() {
        var rule = GrantRule()
        _ = rule.read(granted: false, engineStarted: false)
        _ = rule.read(granted: true, engineStarted: false)
        _ = rule.relaunchAttempted(started: false, engineStarted: true)
        #expect(rule.read(granted: false, engineStarted: true) == .showOnboarding)
        #expect(rule.read(granted: true, engineStarted: true) == .restartObserving)
        #expect(rule.read(granted: true, engineStarted: true) == .nothing)
    }

    @Test func aRevokeShowsTheOnboarding() {
        var rule = GrantRule()
        _ = rule.read(granted: true, engineStarted: true)
        #expect(rule.read(granted: false, engineStarted: true) == .showOnboarding)
    }
}
