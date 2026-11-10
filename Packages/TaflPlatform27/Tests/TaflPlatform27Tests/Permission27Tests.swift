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

/// Answers each call from a script, in call order, and says when a call starts. A call can be held
/// until a gate stream finishes.
private final class ScriptedCheck: Sendable {
    private let answers: Mutex<[Bool?]>
    private let started = Mutex(0)
    private let startedEvents: AsyncStream<Void>
    private let startedContinuation: AsyncStream<Void>.Continuation
    private let hold: (call: Int, gate: AsyncStream<Void>)?

    init(_ answers: [Bool?], holdingCall call: Int? = nil, until gate: AsyncStream<Void> = AsyncStream { $0.finish() }) {
        self.answers = Mutex(answers)
        (startedEvents, startedContinuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .unbounded)
        hold = call.map { ($0, gate) }
    }

    var callCount: Int { started.withLock { $0 } }

    func call() async -> Bool? {
        let number = started.withLock { count in
            count += 1
            return count
        }
        let answer = answers.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        startedContinuation.yield()
        if let hold, hold.call == number {
            for await _ in hold.gate {}
        }
        return answer
    }

    /// Returns once `count` calls have started. Checks run one at a time, so a call starts only after
    /// the one before it has been applied. A wait that is cancelled first (a time limit) records an issue.
    func waitForCalls(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
        if callCount >= count { return }
        for await _ in startedEvents where callCount >= count { return }
        Issue.record("Wait for \(count) calls ended by cancellation at \(callCount)", sourceLocation: sourceLocation)
    }
}

private final class Scheduled: Sendable {
    let delays = Mutex<[Duration]>([])
    let work = Mutex<[@Sendable () -> Void]>([])

    func schedule(_ delay: Duration, _ body: @escaping @Sendable () -> Void) {
        delays.withLock { $0.append(delay) }
        work.withLock { $0.append(body) }
    }

    func runNext() {
        let next = work.withLock { items in items.isEmpty ? nil : items.removeFirst() }
        next?()
    }

    func runAll() {
        let pending = work.withLock { items in
            defer { items = [] }
            return items
        }
        for body in pending { body() }
    }
}

private func permission(
    initial: Bool = false, center: NotificationCenter = NotificationCenter(), scheduled: Scheduled = Scheduled(),
    check: @escaping @Sendable () async -> Bool?, fallback: (@Sendable () -> Bool)? = nil
) -> Permission27 {
    Permission27(
        center: center, name: name, initial: { initial }, check: check, fallback: fallback ?? { initial },
        after: scheduled.schedule)
}

@MainActor
@Test(.timeLimit(.minutes(1))) func aChangedResultIsEmittedOnceAndBecomesTheValue() async {
    let script = ScriptedCheck([true, false])
    let center = NotificationCenter()
    let scheduled = Scheduled()
    let permission = permission(center: center, scheduled: scheduled, check: script.call)
    center.post(name: name, object: nil)
    await script.waitForCalls(1)
    scheduled.runAll()
    #expect(await collect(permission.changes, count: 2) == [true, false])
    #expect(!permission.isTrusted)
}

@MainActor
@Test func theInitialValueIsWhatTheInitialReadAnswers() {
    #expect(permission(initial: true, check: { nil }).isTrusted)
    #expect(!permission(initial: false, check: { nil }).isTrusted)
}

@MainActor
@Test func readingTheValueNeverRunsTheCheck() {
    let script = ScriptedCheck([true])
    let permission = permission(check: script.call)
    _ = permission.isTrusted
    _ = permission.isTrusted
    #expect(script.callCount == 0)
}

@MainActor
@Test(.timeLimit(.minutes(1))) func aNotificationChecksAtOnceAndAtHalfASecondAndTwoSeconds() async {
    let script = ScriptedCheck([nil, nil, nil])
    let scheduled = Scheduled()
    let center = NotificationCenter()
    let permission = permission(center: center, scheduled: scheduled, check: script.call)
    center.post(name: name, object: nil)
    await script.waitForCalls(1)
    #expect(scheduled.delays.withLock { $0 } == [.milliseconds(500), .seconds(2)])
    #expect(script.callCount == 1)
    scheduled.runNext()
    await script.waitForCalls(2)
    scheduled.runNext()
    await script.waitForCalls(3)
    #expect(script.callCount == 3)
    withExtendedLifetime(permission) {}
}

@MainActor
@Test(.timeLimit(.minutes(1))) func resultsApplyInCheckOrderEvenWhenAnEarlierCheckIsSlow() async {
    let (gate, release) = AsyncStream<Void>.makeStream()
    // Call 1 is slow and answers true; call 2 answers false. Side by side, the late true would win.
    let script = ScriptedCheck([true, false], holdingCall: 1, until: gate)
    let scheduled = Scheduled()
    let center = NotificationCenter()
    let permission = permission(center: center, scheduled: scheduled, check: script.call)
    center.post(name: name, object: nil)
    await script.waitForCalls(1)
    scheduled.runAll()
    release.finish()
    #expect(await collect(permission.changes, count: 2) == [true, false])
    #expect(!permission.isTrusted)
}

@MainActor
@Test(.timeLimit(.minutes(1))) func aFailedCheckAnswersWithTheFallback() async {
    let script = ScriptedCheck([nil, nil, nil])
    let scheduled = Scheduled()
    let center = NotificationCenter()
    let permission = permission(
        initial: true, center: center, scheduled: scheduled, check: script.call, fallback: { false })
    center.post(name: name, object: nil)
    scheduled.runAll()
    #expect(await collect(permission.changes, count: 1) == [false])
    #expect(!permission.isTrusted)
}

@MainActor
@Test(.timeLimit(.minutes(1))) func aCheckThatAnswersIsNotReplacedByTheFallback() async {
    let script = ScriptedCheck([false, false, false])
    let center = NotificationCenter()
    let permission = permission(initial: true, center: center, check: script.call, fallback: { true })
    center.post(name: name, object: nil)
    #expect(await collect(permission.changes, count: 1) == [false])
    #expect(!permission.isTrusted)
}

@MainActor
@Test(.timeLimit(.minutes(1))) func requestsDuringACheckLeadToExactlyOneMoreCheck() async {
    let (gate, release) = AsyncStream<Void>.makeStream()
    let script = ScriptedCheck([true, false, false, false], holdingCall: 1, until: gate)
    let scheduled = Scheduled()
    let center = NotificationCenter()
    var held: Permission27? = permission(center: center, scheduled: scheduled, check: script.call)
    var changes = held!.changes.makeAsyncIterator()
    center.post(name: name, object: nil)
    await script.waitForCalls(1)
    for _ in 0..<4 { center.post(name: name, object: nil) }
    scheduled.runAll()
    release.finish()
    #expect(await changes.next() == true)
    #expect(await changes.next() == false)
    held = nil
    #expect(await changes.next() == nil)
    #expect(script.callCount == 2)
}

@MainActor
@Test(.timeLimit(.minutes(1))) func theStreamEndsWhenThePermissionObjectGoes() async {
    var held: Permission27? = permission(check: { nil })
    var changes = held!.changes.makeAsyncIterator()
    held = nil
    #expect(await changes.next() == nil)
}
