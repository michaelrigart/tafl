import ApplicationServices
import Foundation
import Synchronization
import Testing
@testable import TaflPlatform27

private let name = Notification.Name("com.apple.accessibility.api.test")

/// A permission whose reported answer is `reported` and for which every real call answers `call`.
private func permission(
    center: NotificationCenter = NotificationCenter(), call: AXError = .apiDisabled,
    reported: @escaping @Sendable () -> Bool
) -> Permission27 {
    Permission27(center: center, name: name, reported: reported, call: { call })
}

private func collect(_ stream: AsyncStream<Bool>, count: Int) async -> [Bool] {
    var values: [Bool] = []
    for await value in stream {
        values.append(value)
        if values.count == count { break }
    }
    return values
}

@MainActor
@Test(.timeLimit(.minutes(1))) func aChangedValueIsEmittedOncePerChange() async {
    let trusted = Mutex(false)
    let center = NotificationCenter()
    let permission = permission(center: center) { trusted.withLock { $0 } }
    var changes = permission.changes.makeAsyncIterator()
    trusted.withLock { $0 = true }
    center.post(name: name, object: nil)
    center.post(name: name, object: nil)
    #expect(await changes.next() == true)
    trusted.withLock { $0 = false }
    center.post(name: name, object: nil)
    #expect(await changes.next() == false)
}

@MainActor
@Test(.timeLimit(.minutes(1))) func aValueThatTakesEffectAfterTheNotificationIsStillEmitted() async {
    let reads = Mutex(0)
    let center = NotificationCenter()
    // Reads: one at creation, one on the notification, one on the next main run-loop turn.
    let permission = permission(center: center) { reads.withLock { $0 += 1; return $0 >= 3 } }
    center.post(name: name, object: nil)
    #expect(await collect(permission.changes, count: 1) == [true])
}

@MainActor
@Test(.timeLimit(.minutes(1))) func aNotificationWithoutAChangeEmitsNothingAndTheNextChangeFollows() async {
    let trusted = Mutex(true)
    let center = NotificationCenter()
    let permission = permission(center: center) { trusted.withLock { $0 } }
    center.post(name: name, object: nil)
    trusted.withLock { $0 = false }
    center.post(name: name, object: nil)
    #expect(await collect(permission.changes, count: 1) == [false])
}

@MainActor
@Test(.timeLimit(.minutes(1))) func theStreamEndsWhenThePermissionObjectGoes() async {
    var permission: Permission27? = permission { false }
    var changes = permission!.changes.makeAsyncIterator()
    permission = nil
    #expect(await changes.next() == nil)
}

@Test func aGrantTheProcessReportsIsTrustedWithoutARealCall() {
    let permission = permission(call: .apiDisabled) { true }
    #expect(permission.isTrusted)
    #expect(permission.observe().call == nil)
}

@Test func aGrantMacOSAnswersARealCallForIsTrustedWhenTheProcessStillReportsNone() {
    for answer in [AXError.success, .noValue, .attributeUnsupported] {
        let permission = permission(call: answer) { false }
        #expect(permission.isTrusted, "call answered \(answer.rawValue)")
    }
}

@Test func aCallMacOSRefusesIsNotTrusted() {
    let permission = permission(call: .apiDisabled) { false }
    #expect(!permission.isTrusted)
}

@Test func aCallThatTimesOutIsNotTrusted() {
    let permission = permission(call: .cannotComplete) { false }
    #expect(!permission.isTrusted)
}

@Test func theSummaryNamesBothAnswers() {
    #expect(permission(call: .apiDisabled) { false }.observe().summary == "reported=false call=apiDisabled")
    #expect(permission(call: .apiDisabled) { true }.observe().summary == "reported=true call=not needed")
    #expect(permission(call: .illegalArgument) { false }.observe().summary == "reported=false call=-25201")
}

@MainActor
@Test(.timeLimit(.minutes(1))) func theStreamEmitsATrustOnlyTheCallConfirms() async {
    let answer = Mutex(AXError.apiDisabled)
    let center = NotificationCenter()
    let permission = Permission27(center: center, name: name, reported: { false }, call: { answer.withLock { $0 } })
    answer.withLock { $0 = .success }
    center.post(name: name, object: nil)
    #expect(await collect(permission.changes, count: 1) == [true])
}
