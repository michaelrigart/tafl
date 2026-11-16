import Foundation
import Synchronization
import Testing
import TaflTestSupport
@testable import TaflPlatform27

private let name = Notification.Name("com.apple.accessibility.api.test")

/// The first `count` values the permission sends.
private func values(_ changes: Collector<Bool>, count: Int, sourceLocation: SourceLocation = #_sourceLocation) async -> [Bool?] {
    var values: [Bool?] = []
    for _ in 0..<count { values.append(await changes.next(sourceLocation: sourceLocation)) }
    return values
}

/// Answers each call from a script, in call order, and counts the calls that start. One call can be
/// held at a gate, as a slow child check is.
private final class ScriptedCheck: Sendable {
    private let answers: Mutex<[Bool?]>
    private let calls = Mutex(0)
    private let started = Tally()
    private let hold: (call: Int, gate: Gate)?

    init(_ answers: [Bool?], holdingCall call: Int? = nil, at gate: Gate? = nil) {
        self.answers = Mutex(answers)
        hold = call.flatMap { call in gate.map { (call, $0) } }
    }

    var callCount: Int { started.value }

    func call() async -> Bool? {
        let number = calls.withLock { count in
            count += 1
            return count
        }
        let answer = answers.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        started.increment()
        if let hold, hold.call == number {
            await hold.gate.hold()
        }
        return answer
    }

    /// Returns once `count` calls have started. Checks run one at a time, so a call starts only after
    /// the one before it has been applied.
    func waitForCalls(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
        await started.wait(for: count, "checks started", sourceLocation: sourceLocation)
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
    #expect(await values(Collector(permission.changes), count: 2) == [true, false])
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
@Test(.gated, .timeLimit(.minutes(1))) func resultsApplyInCheckOrderEvenWhenAnEarlierCheckIsSlow() async {
    let gate = Gate()
    // Call 1 is slow and answers true; call 2 answers false. Side by side, the late true would win.
    let script = ScriptedCheck([true, false], holdingCall: 1, at: gate)
    let scheduled = Scheduled()
    let center = NotificationCenter()
    let permission = permission(center: center, scheduled: scheduled, check: script.call)
    center.post(name: name, object: nil)
    await script.waitForCalls(1)
    scheduled.runAll()
    gate.open()
    #expect(await values(Collector(permission.changes), count: 2) == [true, false])
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
    #expect(await values(Collector(permission.changes), count: 1) == [false])
    #expect(!permission.isTrusted)
}

@MainActor
@Test(.timeLimit(.minutes(1))) func aCheckThatAnswersIsNotReplacedByTheFallback() async {
    let script = ScriptedCheck([false, false, false])
    let center = NotificationCenter()
    let permission = permission(initial: true, center: center, check: script.call, fallback: { true })
    center.post(name: name, object: nil)
    #expect(await values(Collector(permission.changes), count: 1) == [false])
    #expect(!permission.isTrusted)
}

@MainActor
@Test(.gated, .timeLimit(.minutes(1))) func requestsDuringACheckLeadToExactlyOneMoreCheck() async {
    let gate = Gate()
    let script = ScriptedCheck([true, false, false, false], holdingCall: 1, at: gate)
    let scheduled = Scheduled()
    let center = NotificationCenter()
    var held: Permission27? = permission(center: center, scheduled: scheduled, check: script.call)
    let changes = Collector(held!.changes)
    center.post(name: name, object: nil)
    await script.waitForCalls(1)
    for _ in 0..<4 { center.post(name: name, object: nil) }
    scheduled.runAll()
    gate.open()
    #expect(await changes.next() == true)
    #expect(await changes.next() == false)
    held = nil
    #expect(await changes.waitForEnd())
    #expect(changes.all == [true, false])
    #expect(script.callCount == 2)
}

@MainActor
@Test(.timeLimit(.minutes(1))) func theStreamEndsWhenThePermissionObjectGoes() async {
    var held: Permission27? = permission(check: { nil })
    let changes = Collector(held!.changes)
    held = nil
    #expect(await changes.waitForEnd())
    #expect(changes.all.isEmpty)
}
