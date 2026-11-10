import ApplicationServices
import Testing
@testable import TaflPlatform27

@Test func aRaisedWindowMakesItsAppFrontmost() {
    var asked: [String] = []
    let outcome = Raise27.bringForward(
        raise: { asked.append("raise"); return .success },
        makeFrontmost: { asked.append("frontmost"); return .success })
    #expect(outcome == .raised)
    #expect(asked == ["raise", "frontmost"])
}

@Test func aWindowThatCannotBeRaisedDoesNotBringItsAppForward() {
    var asked: [String] = []
    let outcome = Raise27.bringForward(
        raise: { asked.append("raise"); return .invalidUIElement },
        makeFrontmost: { asked.append("frontmost"); return .success })
    #expect(outcome == .failed(.invalidUIElement))
    #expect(asked == ["raise"])
}

@Test func anAppThatRefusesTheFrontmostWriteIsReportedForTheFallback() {
    let outcome = Raise27.bringForward(raise: { .success }, makeFrontmost: { .cannotComplete })
    #expect(outcome == .raisedWithoutFrontmost)
}
