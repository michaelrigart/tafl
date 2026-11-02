import Testing
@testable import TaflCore

struct TitleCheckTests {
    private let handle = WindowHandle(pid: 1, windowID: 1, isStable: true)
    private let other = WindowHandle(pid: 1, windowID: 2, isStable: true)

    private var applied: MoveRequest {
        MoveRequest(
            window: handle, spec: .named(.firstThird), display: displayA.identity,
            placement: .firstThird, cycleStep: 0, source: .newWindow(layout: "Desk")
        )
    }

    @Test func titleCheckWindow() {
        var check = TitleCheck()
        check.created(handle, at: .zero, applied: applied)
        #expect(check.titleChanged(handle, at: .milliseconds(600), touched: false) == .some(applied))
        #expect(check.titleChanged(handle, at: .milliseconds(700), touched: false) == nil)

        check.created(handle, at: .zero, applied: applied)
        #expect(check.titleChanged(handle, at: .milliseconds(1200), touched: false) == nil)

        check.created(handle, at: .zero, applied: applied)
        #expect(check.titleChanged(handle, at: .milliseconds(600), touched: true) == nil)
        #expect(check.titleChanged(handle, at: .milliseconds(700), touched: false) == nil)
    }

    @Test func exactlyOneSecondStillCounts() {
        var check = TitleCheck()
        check.created(handle, at: .seconds(5), applied: applied)
        #expect(check.titleChanged(handle, at: .seconds(6), touched: false) == .some(applied))
    }

    @Test func windowCreatedWithoutPlacementStillGetsOneRecheck() {
        var check = TitleCheck()
        check.created(handle, at: .zero, applied: nil)
        let result = check.titleChanged(handle, at: .milliseconds(100), touched: false)
        #expect(result == .some(nil))
        #expect(check.titleChanged(handle, at: .milliseconds(200), touched: false) == nil)
    }

    @Test func unknownWindowIsNil() {
        var check = TitleCheck()
        #expect(check.titleChanged(handle, at: .zero, touched: false) == nil)
    }

    @Test func forgetDropsTheWindow() {
        var check = TitleCheck()
        check.created(handle, at: .zero, applied: applied)
        check.created(other, at: .zero, applied: nil)
        check.forget(handle)
        #expect(check.titleChanged(handle, at: .milliseconds(100), touched: false) == nil)
        #expect(check.titleChanged(other, at: .milliseconds(100), touched: false) == .some(nil))
    }
}
