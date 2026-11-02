import ApplicationServices
import Testing
import TaflCore
@testable import TaflPlatform27

@Test func registrationFailuresNameTheEventsMissing() {
    let failed: Set<String> = [kAXWindowMovedNotification, kAXUIElementDestroyedNotification, "AXSomethingElse"]
    #expect(WindowObservation27.observedEvents(for: failed) == [.moved, .destroyed])
    #expect(WindowObservation27.observedEvents(for: Set(AXObserverHub.notifications)) == [.created, .moved, .resized, .titleChanged, .destroyed])
}

@Test func onlyATimeoutIsWorthOneMoreTryWhenTheAppFinishesLaunching() {
    #expect(WindowObservation27.needsRetry([kAXWindowMovedNotification: .cannotComplete]))
    #expect(WindowObservation27.needsRetry([kAXWindowMovedNotification: .failure, kAXTitleChangedNotification: .cannotComplete]))
    #expect(!WindowObservation27.needsRetry([kAXWindowMovedNotification: .notificationUnsupported]))
    #expect(!WindowObservation27.needsRetry([:]))
}

@Test func anObserverThatCannotBeMadeNamesEveryNotification() {
    // A process that does not exist: AXObserverCreate fails, and each notification carries the error.
    let hub = AXObserverHub()
    let failures = hub.observe(pid: 999_999, bundleID: nil) { _ in }
    #expect(Set(failures.keys) == Set(AXObserverHub.notifications))
    #expect(failures.values.allSatisfy { $0 != .success })
}
