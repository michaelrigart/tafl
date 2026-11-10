import Synchronization
import Testing

/// The one way a waiting caller and its bound meet: whichever of the task's end, the bound or the
/// caller's own cancellation comes first resumes the caller; the rest are ignored.
private final class FirstFinish<Outcome: Sendable>: Sendable {
    private enum State {
        case waiting
        case parked(CheckedContinuation<Outcome, Never>)
        case done(Outcome)
    }

    private let state = Mutex(State.waiting)

    func park(_ continuation: CheckedContinuation<Outcome, Never>) {
        let ready = state.withLock { state -> Outcome? in
            if case .done(let outcome) = state { return outcome }
            state = .parked(continuation)
            return nil
        }
        if let ready { continuation.resume(returning: ready) }
    }

    func finish(_ outcome: Outcome) {
        let parked = state.withLock { state -> CheckedContinuation<Outcome, Never>? in
            switch state {
            case .waiting:
                state = .done(outcome)
                return nil
            case .parked(let continuation):
                state = .done(outcome)
                return continuation
            case .done:
                return nil
            }
        }
        parked?.resume(returning: outcome)
    }
}

private enum Ended<Success: Sendable>: Sendable {
    case result(Success)
    case boundPassed
    case callerCancelled
}

/// Awaits an unstructured task for at most `timeout` of wall-clock time. A time limit cancels a test
/// but does not end `await task.value` on a task that ignores cancellation, nor resume a checked
/// continuation, so a test that awaits a task directly hangs instead of failing. This races the
/// task's end against the bound instead: when the bound passes (or the caller is cancelled first) it
/// cancels the task, records an issue and returns nil, without awaiting the stuck task itself.
public func awaitBounded<Success: Sendable>(
    timeout: Duration,
    cancelling cancel: @escaping @Sendable () -> Void,
    sourceLocation: SourceLocation,
    _ finished: @escaping @Sendable () async -> Success
) async -> Success? {
    let race = FirstFinish<Ended<Success>>()
    // The task's own end is awaited in an unstructured task, which a task that never ends leaves behind.
    Task { race.finish(.result(await finished())) }
    let bound = Task {
        try? await Task.sleep(for: timeout)
        race.finish(.boundPassed)
    }
    let ended = await withTaskCancellationHandler {
        await withCheckedContinuation { race.park($0) }
    } onCancel: {
        race.finish(.callerCancelled)
    }
    bound.cancel()
    switch ended {
    case .result(let value):
        return value
    case .boundPassed:
        cancel()
        Issue.record("A task did not finish within \(timeout)", sourceLocation: sourceLocation)
        return nil
    case .callerCancelled:
        cancel()
        Issue.record("The wait for a task was cancelled before the task finished", sourceLocation: sourceLocation)
        return nil
    }
}

extension Task where Failure == Never {
    /// The task's value, or nil with a recorded issue when it has not finished within `timeout`.
    @discardableResult
    public func bounded(timeout: Duration = .seconds(5), sourceLocation: SourceLocation = #_sourceLocation) async -> Success? {
        await awaitBounded(timeout: timeout, cancelling: { self.cancel() }, sourceLocation: sourceLocation) {
            await self.value
        }
    }
}

extension Task where Failure == any Error {
    /// The task's result, or nil with a recorded issue when it has not finished within `timeout`; a
    /// task that ends by throwing rethrows its error.
    @discardableResult
    public func bounded(timeout: Duration = .seconds(5), sourceLocation: SourceLocation = #_sourceLocation) async throws -> Success? {
        let result = await awaitBounded(timeout: timeout, cancelling: { self.cancel() }, sourceLocation: sourceLocation) {
            await self.result
        }
        return try result?.get()
    }
}
