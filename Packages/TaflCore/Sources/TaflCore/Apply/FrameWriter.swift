import Foundation

public struct WriteJob: Sendable {
    public var window: WindowHandle
    public var appName: String
    public var start: ScreenRect
    public var target: ScreenRect
    public var targetVisible: ScreenRect
    public var crossesDisplays: Bool
    public var minSize: ScreenSize?
    public var displays: [Display]

    public init(
        window: WindowHandle,
        appName: String,
        start: ScreenRect,
        target: ScreenRect,
        targetVisible: ScreenRect,
        crossesDisplays: Bool,
        minSize: ScreenSize?,
        displays: [Display]
    ) {
        self.window = window
        self.appName = appName
        self.start = start
        self.target = target
        self.targetVisible = targetVisible
        self.crossesDisplays = crossesDisplays
        self.minSize = minSize
        self.displays = displays
    }
}

public enum WriteResult: Equatable, Sendable {
    case placed(ScreenRect)
    case sizeRefused(ScreenRect)
    case positionRefused(ScreenRect)
    case interrupted
    case failed(PlatformFailure, lastVerified: ScreenRect?)
    /// `lastVerified` is the last frame read back that passed its check; nil when nothing was written.
    case cancelled(lastVerified: ScreenRect?)
}

/// Applies a frame as a sequence of checked writes: each write is read back and the part it
/// did not set must be unchanged (or explained by a named macOS adjustment), otherwise
/// something else moved the window and the request stops. One request per window at a time;
/// `WindowRequestQueue` provides that.
public actor FrameWriter {
    /// A size short of the target by less than this, and never larger, counts as success.
    private static let shortfallLimit = 30.0
    private static let tolerance = 1.0

    private struct Observation {
        var frame: ScreenRect
        /// The part in flight when the frame was observed.
        var part: WritePart?
    }

    private struct WindowState {
        var expected: ScreenRect
        var inFlight: WritePart?
        var observed: [Observation] = []
        var lastVerified: ScreenRect?
        var awaitingFirstWrite = true
    }

    private struct Stop: Error {
        var result: WriteResult
    }

    private let platform: any WindowPlatform
    private let clock: any TaflClock
    private let adjustments: [MacOSAdjustment]
    private let reapplyDelay: Duration?
    private var epoch = 0
    private var states: [WindowHandle: WindowState] = [:]

    public init(
        platform: any WindowPlatform,
        clock: any TaflClock,
        adjustments: [MacOSAdjustment],
        reapplyDelay: Duration? = .milliseconds(25)
    ) {
        self.platform = platform
        self.clock = clock
        self.adjustments = adjustments
        self.reapplyDelay = reapplyDelay
    }

    public func write(_ job: WriteJob, beforeFirstWrite: @Sendable () async -> Void) async -> WriteResult {
        let startEpoch = epoch
        let first = await attempt(job, start: job.start, startEpoch: startEpoch, reapplying: nil, beforeFirstWrite: beforeFirstWrite)
        guard job.crossesDisplays, let delay = reapplyDelay else { return first }
        let achieved: ScreenRect
        switch first {
        case .placed(let frame), .sizeRefused(let frame): achieved = frame
        default: return first
        }
        do {
            try await clock.sleep(for: delay)
        } catch {
            return first
        }
        guard !Task.isCancelled, epoch == startEpoch else { return first }
        return await attempt(job, start: achieved, startEpoch: startEpoch, reapplying: first, beforeFirstWrite: {})
    }

    /// Records a frame read while a request writes this window; ignored otherwise.
    public func observed(_ window: WindowHandle, frame: ScreenRect) {
        guard var state = states[window] else { return }
        state.observed.append(Observation(frame: frame, part: state.inFlight))
        states[window] = state
    }

    public func isWriting(_ window: WindowHandle) -> Bool {
        states[window] != nil
    }

    public func reconfigurationBegan() {
        epoch += 1
    }

    // MARK: A session

    /// One session, from `beginWriting` to `end()`. A reapply (`reapplying` is the earlier
    /// result) first reads the frame, and gives the earlier result back unless the window is
    /// still where that result left it.
    private func attempt(
        _ job: WriteJob,
        start: ScreenRect,
        startEpoch: Int,
        reapplying earlier: WriteResult?,
        beforeFirstWrite: @Sendable () async -> Void
    ) async -> WriteResult {
        states[job.window] = WindowState(expected: start)
        defer { states[job.window] = nil }

        let session: any WriteSession
        switch await platform.beginWriting(job.window) {
        case .failure(let failure): return earlier ?? .failed(failure, lastVerified: nil)
        case .success(let opened): session = opened
        }

        var result: WriteResult
        if let earlier, !(await isStillAt(start, session)) {
            result = earlier
        } else {
            let context = Context(job: job, session: session, startEpoch: startEpoch)
            result = await sequence(context, start: start, beforeFirstWrite: beforeFirstWrite)
            if let earlier, result == .cancelled(lastVerified: nil) { result = earlier }
        }
        await session.end()
        return result
    }

    private func isStillAt(_ frame: ScreenRect, _ session: any WriteSession) async -> Bool {
        guard case .success(let read) = await session.readFrame() else { return false }
        return read.isClose(to: frame, within: Self.tolerance)
    }

    // MARK: The write sequence

    private struct Context: Sendable {
        var job: WriteJob
        var session: any WriteSession
        var startEpoch: Int
    }

    private enum Write {
        case size(ScreenSize)
        case position(ScreenPoint)

        var part: WritePart {
            switch self {
            case .size: .size
            case .position: .position
            }
        }
    }

    private func sequence(
        _ context: Context,
        start: ScreenRect,
        beforeFirstWrite: @Sendable () async -> Void
    ) async -> WriteResult {
        let job = context.job
        let target = job.target
        do throws(Stop) {
            let sizeFirst = WriteOrder.sizeFirst(
                from: start, to: target, bounds: job.targetVisible, acrossDisplays: job.crossesDisplays
            )
            let sizeNeeded = differs(start.size, target.size)
            let positionNeeded = differs(start.origin, target.origin)
            if sizeFirst {
                if sizeNeeded {
                    try await perform(.size(target.size), context, beforeFirstWrite)
                    try await align(context, beforeFirstWrite)
                } else if positionNeeded {
                    try await perform(.position(target.origin), context, beforeFirstWrite)
                }
            } else {
                if positionNeeded { try await perform(.position(target.origin), context, beforeFirstWrite) }
                if sizeNeeded { try await perform(.size(target.size), context, beforeFirstWrite) }
            }
            if differs(expected(job.window).size, target.size) {
                let minimum = job.minSize ?? ScreenSize(width: 0, height: 0)
                let retry = ScreenSize(width: max(target.width, minimum.width), height: max(target.height, minimum.height))
                try await perform(.size(retry), context, beforeFirstWrite)
                try await align(context, beforeFirstWrite)
            }
        } catch {
            return error.result
        }
        return classify(job, achieved: expected(job.window))
    }

    /// One checked write: the checks, the write, the read-back and its check.
    private func perform(
        _ write: Write,
        _ context: Context,
        _ beforeFirstWrite: @Sendable () async -> Void
    ) async throws(Stop) {
        let window = context.job.window
        if let stop = checkpoint(window, startEpoch: context.startEpoch) { throw Stop(result: stop) }
        if states[window]?.awaitingFirstWrite == true {
            states[window]?.awaitingFirstWrite = false
            await beforeFirstWrite()
        }
        beginWrite(window, write.part)
        let written = switch write {
        case .size(let size): await context.session.setSize(size)
        case .position(let point): await context.session.setPosition(point)
        }
        if case .failure(let failure) = written { throw Stop(result: failed(window, failure)) }
        switch await context.session.readFrame() {
        case .failure(let failure): throw Stop(result: failed(window, failure))
        case .success(let frame): if !commit(context.job, write.part, frame) { throw Stop(result: .interrupted) }
        }
    }

    /// Moves the window to where its accepted size belongs, when it isn't there.
    private func align(_ context: Context, _ beforeFirstWrite: @Sendable () async -> Void) async throws(Stop) {
        let job = context.job
        let frame = expected(job.window)
        let destination = EdgeAligner.origin(for: job.target, actualSize: frame.size, visible: job.targetVisible)
        if differs(frame.origin, destination) { try await perform(.position(destination), context, beforeFirstWrite) }
    }

    private func classify(_ job: WriteJob, achieved: ScreenRect) -> WriteResult {
        let target = job.target
        let aligned = EdgeAligner.origin(for: target, actualSize: achieved.size, visible: job.targetVisible)
        if differs(achieved.origin, aligned) { return .positionRefused(achieved) }
        if achieved.isClose(to: target, within: Self.tolerance)
            || (isShort(target.width - achieved.width) && isShort(target.height - achieved.height)) {
            return .placed(achieved)
        }
        return .sizeRefused(achieved)
    }

    /// Within a point of the target, or short by less than the limit and never larger.
    private func isShort(_ shortfall: Double) -> Bool {
        shortfall >= -Self.tolerance && shortfall < Self.shortfallLimit
    }

    // MARK: Per-window state

    private func expected(_ window: WindowHandle) -> ScreenRect {
        states[window]?.expected ?? ScreenRect(x: 0, y: 0, width: 0, height: 0)
    }

    /// The checks before a write: cancellation and reconfiguration, then frames observed
    /// since the last check.
    private func checkpoint(_ window: WindowHandle, startEpoch: Int) -> WriteResult? {
        guard var state = states[window] else { return .interrupted }
        if Task.isCancelled || epoch != startEpoch { return .cancelled(lastVerified: state.lastVerified) }
        let observed = state.observed
        state.observed = []
        states[window] = state
        for observation in observed {
            let positionMoved = differs(observation.frame.origin, state.expected.origin) && observation.part != .position
            let sizeChanged = differs(observation.frame.size, state.expected.size) && observation.part != .size
            if positionMoved || sizeChanged { return .interrupted }
        }
        return nil
    }

    private func beginWrite(_ window: WindowHandle, _ part: WritePart) {
        states[window]?.inFlight = part
        states[window]?.lastVerified = nil
    }

    private func failed(_ window: WindowHandle, _ failure: PlatformFailure) -> WriteResult {
        .failed(failure, lastVerified: states[window]?.lastVerified)
    }

    /// Checks a read-back: the part not written must be unchanged or explained by an
    /// adjustment. A pass makes the frame read the expected and last verified one.
    private func commit(_ job: WriteJob, _ part: WritePart, _ read: ScreenRect) -> Bool {
        guard var state = states[job.window] else { return false }
        state.inFlight = nil
        defer { states[job.window] = state }

        let otherChanged = switch part {
        case .size: differs(read.origin, state.expected.origin)
        case .position: differs(read.size, state.expected.size)
        }
        if otherChanged {
            let adjustmentCase = AdjustmentCase(
                written: part, before: state.expected, after: read,
                targetVisible: job.targetVisible, displays: job.displays
            )
            guard adjustments.contains(where: { $0.explains(adjustmentCase) }) else { return false }
        }
        state.expected = read
        state.lastVerified = read
        return true
    }

    private func differs(_ a: ScreenPoint, _ b: ScreenPoint) -> Bool {
        abs(a.x - b.x) > Self.tolerance || abs(a.y - b.y) > Self.tolerance
    }

    private func differs(_ a: ScreenSize, _ b: ScreenSize) -> Bool {
        abs(a.width - b.width) > Self.tolerance || abs(a.height - b.height) > Self.tolerance
    }
}
