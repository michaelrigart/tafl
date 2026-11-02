import Testing
@testable import TaflCore

struct SettleTrackerTests {
    @Test func severalReconfigurationsSettleOnce() {
        var tracker = SettleTracker(quietPeriod: .seconds(1))
        tracker.began(at: .zero)
        tracker.ended(at: .milliseconds(200))
        tracker.began(at: .milliseconds(400))
        tracker.ended(at: .milliseconds(500))
        tracker.windowMoved(at: .milliseconds(900))
        #expect(tracker.settleIfDue(now: .milliseconds(1800)) == false)
        #expect(tracker.settleIfDue(now: .milliseconds(1900)) == true)
        #expect(tracker.settleIfDue(now: .milliseconds(2500)) == false)
        #expect(tracker.isChanging == false)
    }

    @Test func waitsForTheEnd() {
        var tracker = SettleTracker(quietPeriod: .seconds(1))
        tracker.began(at: .zero)
        #expect(tracker.deadline == nil)
        #expect(tracker.settleIfDue(now: .milliseconds(1500)) == false)
        #expect(tracker.settleIfDue(now: .milliseconds(2400)) == false)
        tracker.ended(at: .milliseconds(2500))
        #expect(tracker.settleIfDue(now: .milliseconds(3400)) == false)
        #expect(tracker.settleIfDue(now: .milliseconds(3500)) == true)
    }

    @Test func openReconfigurationNeverSettles() {
        var tracker = SettleTracker(quietPeriod: .seconds(1))
        tracker.began(at: .zero)
        #expect(tracker.settleIfDue(now: .seconds(60)) == false)
        #expect(tracker.isChanging)
    }

    @Test func windowMovesAreIgnoredWhileNotChanging() {
        var tracker = SettleTracker(quietPeriod: .seconds(1))
        tracker.windowMoved(at: .seconds(5))
        #expect(tracker.isChanging == false)
        #expect(tracker.deadline == nil)
        #expect(tracker.settleIfDue(now: .seconds(10)) == false)
    }

    @Test func windowMovesPushTheDeadline() {
        var tracker = SettleTracker(quietPeriod: .seconds(1))
        tracker.began(at: .zero)
        tracker.ended(at: .milliseconds(100))
        tracker.windowMoved(at: .milliseconds(600))
        #expect(tracker.deadline == .milliseconds(1600))
    }

    @Test func anEarlierInputNeverPullsTheDeadlineBack() {
        var tracker = SettleTracker(quietPeriod: .seconds(1))
        tracker.began(at: .zero)
        tracker.ended(at: .milliseconds(100))
        tracker.windowMoved(at: .milliseconds(900))
        tracker.windowMoved(at: .milliseconds(300))
        #expect(tracker.deadline == .milliseconds(1900))
    }

    @Test func quietPeriodIsCapped() async {
        await #expect(processExitsWith: .failure) { _ = SettleTracker(quietPeriod: .seconds(4)) }
    }

    @Test func quietPeriodAtTheCapIsAccepted() {
        let tracker = SettleTracker(quietPeriod: .seconds(3))
        #expect(tracker.quietPeriod == .seconds(3))
    }
}
