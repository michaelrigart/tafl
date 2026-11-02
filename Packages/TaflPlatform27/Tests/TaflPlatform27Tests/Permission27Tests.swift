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
@Test func aChangedValueIsEmittedOncePerChange() async {
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
@Test func aValueThatTakesEffectAfterTheNotificationIsStillEmitted() async {
    let reads = Mutex(0)
    let center = NotificationCenter()
    // Reads: one at creation, one on the notification, one on the next main run-loop turn.
    let permission = Permission27(center: center, name: name) { reads.withLock { $0 += 1; return $0 >= 3 } }
    center.post(name: name, object: nil)
    #expect(await collect(permission.changes, count: 1) == [true])
}

@MainActor
@Test func aNotificationWithoutAChangeEmitsNothingAndTheNextChangeFollows() async {
    let trusted = Mutex(true)
    let center = NotificationCenter()
    let permission = Permission27(center: center, name: name) { trusted.withLock { $0 } }
    center.post(name: name, object: nil)
    trusted.withLock { $0 = false }
    center.post(name: name, object: nil)
    #expect(await collect(permission.changes, count: 1) == [false])
}

@MainActor
@Test func theStreamEndsWhenThePermissionObjectGoes() async {
    var permission: Permission27? = Permission27(center: NotificationCenter(), name: name) { false }
    var changes = permission!.changes.makeAsyncIterator()
    permission = nil
    #expect(await changes.next() == nil)
}
