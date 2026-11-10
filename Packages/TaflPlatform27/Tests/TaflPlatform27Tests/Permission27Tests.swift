import Foundation
import Synchronization
import Testing
@testable import TaflPlatform27

private let name = Notification.Name("com.apple.accessibility.api.test")

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
    let permission = Permission27(center: center, name: name) { trusted.withLock { $0 } }
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
    let permission = Permission27(center: center, name: name) { reads.withLock { $0 += 1; return $0 >= 3 } }
    center.post(name: name, object: nil)
    #expect(await collect(permission.changes, count: 1) == [true])
}

@MainActor
@Test(.timeLimit(.minutes(1))) func aNotificationWithoutAChangeEmitsNothingAndTheNextChangeFollows() async {
    let trusted = Mutex(true)
    let center = NotificationCenter()
    let permission = Permission27(center: center, name: name) { trusted.withLock { $0 } }
    center.post(name: name, object: nil)
    trusted.withLock { $0 = false }
    center.post(name: name, object: nil)
    #expect(await collect(permission.changes, count: 1) == [false])
}

@MainActor
@Test(.timeLimit(.minutes(1))) func theStreamEndsWhenThePermissionObjectGoes() async {
    var permission: Permission27? = Permission27(center: NotificationCenter(), name: name) { false }
    var changes = permission!.changes.makeAsyncIterator()
    permission = nil
    #expect(await changes.next() == nil)
}

@Test func isTrustedIsWhatTheReadAnswersEachTime() {
    let trusted = Mutex(true)
    let permission = Permission27(center: NotificationCenter(), name: name) { trusted.withLock { $0 } }
    #expect(permission.isTrusted)
    trusted.withLock { $0 = false }
    #expect(!permission.isTrusted)
}

private final class Scheduled: Sendable {
    let delays = Mutex<[Duration]>([])
    let work = Mutex<[@Sendable () -> Void]>([])

    func schedule(_ delay: Duration, _ body: @escaping @Sendable () -> Void) {
        delays.withLock { $0.append(delay) }
        work.withLock { $0.append(body) }
    }

    func runAll() {
        let pending = work.withLock { items in
            defer { items = [] }
            return items
        }
        for body in pending { body() }
    }
}

/// Returns once the main queue has run everything queued before the call.
@MainActor private func afterTheNextTurn() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}

@MainActor
@Test(.timeLimit(.minutes(1))) func aValueThatChangesAfterTheNextTurnReadIsEmittedByALaterRead() async {
    let reads = Mutex(0)
    let scheduled = Scheduled()
    let center = NotificationCenter()
    // Reads: creation, the notification, the next main run-loop turn, then the first delayed read.
    let permission = Permission27(
        center: center, name: name,
        read: { reads.withLock { $0 += 1; return $0 >= 4 } },
        after: scheduled.schedule)
    center.post(name: name, object: nil)
    await afterTheNextTurn()
    #expect(reads.withLock { $0 } == 3)
    scheduled.runAll()
    #expect(await collect(permission.changes, count: 1) == [true])
}

@MainActor
@Test(.timeLimit(.minutes(1))) func eachNotificationSchedulesExactlyTheHalfSecondAndTwoSecondReads() async {
    let scheduled = Scheduled()
    let center = NotificationCenter()
    let permission = Permission27(center: center, name: name, read: { false }, after: scheduled.schedule)
    center.post(name: name, object: nil)
    #expect(scheduled.delays.withLock { $0 } == [.milliseconds(500), .seconds(2)])
    withExtendedLifetime(permission) {}
}

@MainActor
@Test(.timeLimit(.minutes(1))) func aDelayedReadThatFindsTheSameValueEmitsNothing() async {
    let trusted = Mutex(false)
    let scheduled = Scheduled()
    let center = NotificationCenter()
    let permission = Permission27(
        center: center, name: name, read: { trusted.withLock { $0 } }, after: scheduled.schedule)
    trusted.withLock { $0 = true }
    center.post(name: name, object: nil)
    await afterTheNextTurn()
    scheduled.runAll()
    trusted.withLock { $0 = false }
    center.post(name: name, object: nil)
    await afterTheNextTurn()
    scheduled.runAll()
    #expect(await collect(permission.changes, count: 2) == [true, false])
}
