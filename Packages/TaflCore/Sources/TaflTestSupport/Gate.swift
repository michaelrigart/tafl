import Synchronization
import Testing

/// What a held call tells about the task it holds. The gate calls it, under its lock, when the call
/// parks; what it returns is called before the task is woken. The engine's tests pass
/// `EngineActivity.parkCurrentTask`, so a call held at a gate counts as waiting for input.
public typealias ParkHook = @Sendable () -> (@Sendable () -> Void)?

/// Holds calls until the test lets them go: a call in flight, as a slow app holds an Accessibility
/// call. A held call ignores cancellation, as a real call in flight does. Every gate belongs to its
/// test's `GateScope` (`@Test(.gated)`), which opens it when the test ends, so no path through a
/// test leaves a call held for good.
public final class Gate: Sendable {
    private struct Held {
        let continuation: CheckedContinuation<Void, Never>
        let unpark: (@Sendable () -> Void)?
    }

    private struct State {
        var isOpen = false
        var held: [Held] = []
    }

    private let state = Mutex(State())

    /// A gate made outside a `.gated` test records an issue: nothing would open it when the test ends.
    public init(sourceLocation: SourceLocation = #_sourceLocation) {
        if let scope = GateScope.current {
            scope.add(self)
        } else {
            Issue.record("A gate needs a test marked .gated, which opens it when the test ends", sourceLocation: sourceLocation)
        }
    }

    /// How many calls are held here now.
    public var heldCount: Int { state.withLock { $0.held.count } }

    /// Holds the caller until the gate opens or releases it; an open gate lets it through at once.
    public func hold(parking park: ParkHook? = nil) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let through = state.withLock { state -> Bool in
                if state.isOpen { return true }
                state.held.append(Held(continuation: continuation, unpark: park?()))
                return false
            }
            if through { continuation.resume() }
        }
    }

    /// Lets every held call go, and every later one through.
    public func open() {
        let held = state.withLock { state -> [Held] in
            state.isOpen = true
            defer { state.held = [] }
            return state.held
        }
        wake(held)
    }

    /// Lets the calls held now go; a later call is held again.
    public func release() {
        let held = state.withLock { state -> [Held] in
            defer { state.held = [] }
            return state.held
        }
        wake(held)
    }

    /// Waits until `count` calls are held here at once. When it fails it opens every gate of the
    /// test, this one included, as every failed wait does.
    @discardableResult
    public func waitUntilHolding(
        _ count: Int,
        timeout: Duration = defaultWaitBound,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        await waitUntil("\(count) held call\(count == 1 ? "" : "s") at a gate", timeout: timeout, sourceLocation: sourceLocation) {
            heldCount >= count
        }
    }

    /// Whoever counts a woken task's work hears of it before the task runs again.
    private func wake(_ held: [Held]) {
        for call in held {
            call.unpark?()
            call.continuation.resume()
        }
    }
}

/// The gates of one test, all opened when it ends, whether it returns, throws, fails a wait or is
/// cancelled. A test that is still running at the scope's bound has a step held at one: the scope
/// records an issue and opens them all, so the test can end and fail.
public final class GateScope: Sendable {
    @TaskLocal public static var current: GateScope?

    private let gates = Mutex<[Gate]>([])

    fileprivate init() {}

    fileprivate func add(_ gate: Gate) {
        gates.withLock { $0.append(gate) }
    }

    /// Opens every gate the test has made.
    public func openAll() {
        for gate in gates.withLock({ $0 }) { gate.open() }
    }

    fileprivate func run(bound: Duration, _ body: () async throws -> Void) async throws {
        let watchdog = Task { [self] in
            guard (try? await Task.sleep(for: bound)) != nil else { return }
            Issue.record("The test was still running after \(bound) with a step held at a gate; every gate is opened")
            openAll()
        }
        defer {
            watchdog.cancel()
            openAll()
        }
        try await Self.$current.withValue(self) {
            try await withTaskCancellationHandler {
                try await body()
            } onCancel: {
                openAll()
            }
        }
    }
}

/// Gives a test a `GateScope`: `@Test(.gated)`.
public struct GatedTrait: TestTrait, TestScoping {
    let bound: Duration

    public func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        try await GateScope().run(bound: bound, function)
    }
}

extension Trait where Self == GatedTrait {
    /// The test's gates open when it ends, and at the latest 30 s after it starts.
    public static var gated: Self { GatedTrait(bound: .seconds(30)) }
}
