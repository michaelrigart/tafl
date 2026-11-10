import ApplicationServices
import Testing
@testable import TaflPlatform27

@Test func aRaisedWindowMakesItsAppFrontmost() {
    var asked: [String] = []
    let outcome = Raise27.bringForward(
        admit: { true },
        raise: { asked.append("raise"); return .success },
        makeFrontmost: { asked.append("frontmost"); return .success })
    #expect(outcome == .raised)
    #expect(asked == ["raise", "frontmost"])
}

@Test func aWindowThatCannotBeRaisedDoesNotBringItsAppForward() {
    var asked: [String] = []
    let outcome = Raise27.bringForward(
        admit: { true },
        raise: { asked.append("raise"); return .invalidUIElement },
        makeFrontmost: { asked.append("frontmost"); return .success })
    #expect(outcome == .failed(.invalidUIElement))
    #expect(asked == ["raise"])
}

@Test func anAppThatRefusesTheFrontmostWriteIsReportedForTheFallback() {
    let outcome = Raise27.bringForward(admit: { true }, raise: { .success }, makeFrontmost: { .cannotComplete })
    #expect(outcome == .raisedWithoutFrontmost)
}

@Test func aRefusedAdmissionBeforeTheRaiseAsksNothing() {
    var asked: [String] = []
    let outcome = Raise27.bringForward(
        admit: { false },
        raise: { asked.append("raise"); return .success },
        makeFrontmost: { asked.append("frontmost"); return .success })
    #expect(outcome == .stopped)
    #expect(asked.isEmpty)
}

@Test func aRefusedAdmissionAfterTheRaiseDoesNotMakeTheAppFrontmost() {
    var asked: [String] = []
    var admissions = 0
    let outcome = Raise27.bringForward(
        admit: { admissions += 1; return admissions == 1 },
        raise: { asked.append("raise"); return .success },
        makeFrontmost: { asked.append("frontmost"); return .success })
    #expect(outcome == .stopped)
    #expect(asked == ["raise"])
}
