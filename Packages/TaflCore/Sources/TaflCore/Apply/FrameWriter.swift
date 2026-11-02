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
    /// The edges of the placement, before gaps, that a window kept at its own size is aligned
    /// to. Empty derives them from the target touching `targetVisible`.
    public var alignment: AlignmentEdges
    public var gap: Double
    /// The reconfiguration epoch this job was planned in; a write started in a later one is
    /// cancelled before it begins.
    public var plannedEpoch: Int?

    public init(
        window: WindowHandle,
        appName: String,
        start: ScreenRect,
        target: ScreenRect,
        targetVisible: ScreenRect,
        crossesDisplays: Bool,
        minSize: ScreenSize?,
        displays: [Display],
        alignment: AlignmentEdges = [],
        gap: Double = 0,
        plannedEpoch: Int? = nil
    ) {
        self.window = window
        self.appName = appName
        self.start = start
        self.target = target
        self.targetVisible = targetVisible
        self.crossesDisplays = crossesDisplays
        self.minSize = minSize
        self.displays = displays
        self.alignment = alignment
        self.gap = gap
        self.plannedEpoch = plannedEpoch
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

/// Whose a frame read for a window is, as `FrameWriter.observe` decides it.
public enum FrameObservation: Equatable, Sendable {
    /// A write for the window is running; the frame was kept and is judged against it.
    case heldForWrite
    /// Within a point of where the window's last write left it.
    case own
    /// Neither: someone else moved the window.
    case external
}

/// Applies a frame as a sequence of checked writes: each write is read back and the part it
/// did not set must be unchanged (or explained by a named macOS adjustment), otherwise
/// something else moved the window and the request stops. One request per window at a time;
/// `WindowRequestQueue` provides that.
public actor FrameWriter {
    /// A size short of the target by less than this, and never larger, counts as success.
    private static let shortfallLimit = 30.0
    private static let tolerance = 1.0

    private struct PendingFrame {
        var frame: ScreenRect
        /// The part in flight when the frame was observed.
        var part: WritePart?
    }

    /// Everything one `write` knows about its window, from entry to return.
    private final class Request {
        let job: WriteJob
        let startEpoch: Int
        /// Frames observed since the last check, kept across sessions.
        var observed: [PendingFrame] = []
        /// Every frame read back and verified in this request, in any session: a notification
        /// for one of them that is read late is still Tafl's own.
        var verified: [ScreenRect] = []
        /// The last frame read back that passed its check, in any session.
        var lastOwn: ScreenRect?
        // The current session's.
        var expected: ScreenRect
        var inFlight: WritePart?
        var lastVerified: ScreenRect?
        var awaitingFirstWrite = true

        init(job: WriteJob, startEpoch: Int) {
            self.job = job
            self.startEpoch = startEpoch
            expected = job.start
        }

        func beginSession(from start: ScreenRect) {
            expected = start
            inFlight = nil
            lastVerified = nil
            awaitingFirstWrite = true
        }
    }

    private struct Context {
        var request: Request
        var session: any WriteSession
    }

    private struct Stop: Error {
        var result: WriteResult
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

    private let platform: any WindowPlatform
    private let clock: any TaflClock
    private let adjustments: [MacOSAdjustment]
    private let reapplyDelay: Duration?
    private var requests: [WindowHandle: Request] = [:]
    private var achieved: [WindowHandle: ScreenRect] = [:]

    /// Bumped when a display reconfiguration begins; a write that started earlier is cancelled.
    public private(set) var epoch = 0

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
        if let planned = job.plannedEpoch, planned != epoch { return .cancelled(lastVerified: nil) }
        let request = Request(job: job, startEpoch: epoch)
        requests[job.window] = request
        achieved[job.window] = nil
        let result = await run(request, beforeFirstWrite)
        if requests[job.window] === request {
            requests[job.window] = nil
            achieved[job.window] = result.frame ?? request.lastOwn
        }
        return result
    }

    /// Decides in one step what a frame read for this window is: `.heldForWrite` while a write
    /// for it runs (the frame is kept and judged against the request), else `.own` when it is
    /// where the window's last write left it, else `.external`.
    public func observe(_ window: WindowHandle, frame: ScreenRect) -> FrameObservation {
        if let request = requests[window] {
            request.observed.append(PendingFrame(frame: frame, part: request.inFlight))
            return .heldForWrite
        }
        if let own = achieved[window], !differs(own, frame) { return .own }
        return .external
    }

    /// Drops the window's last achieved frame, for a window that is gone.
    public func forget(_ window: WindowHandle) {
        achieved[window] = nil
    }

    /// Drops the last achieved frames of an app's windows, for an app that quit.
    public func forget(pid: Int32) {
        achieved = achieved.filter { $0.key.pid != pid }
    }

    /// True from the start of a `write` for this window until it returns, the reapply wait included.
    public func isWriting(_ window: WindowHandle) -> Bool {
        requests[window] != nil
    }

    public func reconfigurationBegan() {
        epoch += 1
    }

    // MARK: The request

    private func run(_ request: Request, _ beforeFirstWrite: @Sendable () async -> Void) async -> WriteResult {
        let job = request.job
        let first = await attempt(request, start: job.start, reapplying: nil, beforeFirstWrite)
        // Rectangle reapplies only when the size came out wrong.
        let frame: ScreenRect
        switch first {
        case .placed(let achieved), .sizeRefused(let achieved): frame = achieved
        default: return first
        }
        guard job.crossesDisplays, let delay = reapplyDelay, differs(frame.size, job.target.size) else { return first }
        do {
            try await clock.sleep(for: delay)
        } catch {
            return judgePending(request) ? .interrupted : first
        }
        guard !Task.isCancelled, epoch == request.startEpoch else { return judgePending(request) ? .interrupted : first }
        if judgePending(request) { return .interrupted }
        return await attempt(request, start: frame, reapplying: first, {})
    }

    /// One session, from `beginWriting` to `end()`. A reapply (`reapplying` is the earlier
    /// result) first reads the frame: a window that is no longer where that result left it
    /// was moved by someone else.
    private func attempt(
        _ request: Request,
        start: ScreenRect,
        reapplying earlier: WriteResult?,
        _ beforeFirstWrite: @Sendable () async -> Void
    ) async -> WriteResult {
        request.beginSession(from: start)
        let session: any WriteSession
        switch await platform.beginWriting(request.job.window) {
        case .failure(let failure):
            guard let earlier else { return .failed(failure, lastVerified: nil) }
            return judgePending(request) ? .interrupted : earlier
        case .success(let opened): session = opened
        }
        let context = Context(request: request, session: session)

        var result: WriteResult
        if let earlier {
            result = await reapply(context, after: earlier, beforeFirstWrite)
        } else {
            result = await sequence(context, beforeFirstWrite)
        }
        await session.end()
        if result.isAchievement, judgePending(request) { result = .interrupted }
        return result
    }

    private func reapply(
        _ context: Context,
        after earlier: WriteResult,
        _ beforeFirstWrite: @Sendable () async -> Void
    ) async -> WriteResult {
        let request = context.request
        if Task.isCancelled || epoch != request.startEpoch { return earlier }
        guard case .success(let read) = await context.session.readFrame() else { return earlier }
        if differs(read, request.expected) { return .interrupted }
        let result = await sequence(context, beforeFirstWrite)
        return result == .cancelled(lastVerified: nil) ? earlier : result
    }

    // MARK: The write sequence

    private func sequence(_ context: Context, _ beforeFirstWrite: @Sendable () async -> Void) async -> WriteResult {
        let request = context.request
        let job = request.job
        let target = job.target
        let start = request.expected
        do throws(Stop) {
            let sizeFirst = WriteOrder.sizeFirst(
                from: start, to: target, bounds: job.targetVisible, acrossDisplays: job.crossesDisplays
            )
            let sizeNeeded = differs(start.size, target.size)
            let positionNeeded = differs(start.origin, target.origin)
            if sizeFirst {
                if sizeNeeded {
                    try await perform(.size(target.size), context, beforeFirstWrite)
                    // As Rectangle does, place the window as if it had the size it asked for, so a
                    // limit that depends on where the window sits doesn't hold the next write back.
                    let accepted = request.expected.size
                    let placed = ScreenSize(width: max(accepted.width, target.width), height: max(accepted.height, target.height))
                    try await align(context, size: placed, beforeFirstWrite)
                } else if positionNeeded {
                    try await perform(.position(target.origin), context, beforeFirstWrite)
                }
            } else {
                if positionNeeded { try await perform(.position(target.origin), context, beforeFirstWrite) }
                if sizeNeeded { try await perform(.size(target.size), context, beforeFirstWrite) }
            }
            let minimum = job.minSize ?? ScreenSize(width: 0, height: 0)
            let retry = ScreenSize(width: max(target.width, minimum.width), height: max(target.height, minimum.height))
            if differs(request.expected.size, target.size), differs(request.expected.size, retry) {
                try await perform(.size(retry), context, beforeFirstWrite)
                try await align(context, size: request.expected.size, beforeFirstWrite)
            }
        } catch {
            return error.result
        }
        return classify(job, achieved: request.expected)
    }

    /// One checked write: the checks, the write, the read-back and its check.
    private func perform(
        _ write: Write,
        _ context: Context,
        _ beforeFirstWrite: @Sendable () async -> Void
    ) async throws(Stop) {
        let request = context.request
        if let stop = checkpoint(request) { throw Stop(result: stop) }
        if request.awaitingFirstWrite {
            request.awaitingFirstWrite = false
            await beforeFirstWrite()
            // The callback is a suspension point: the request may have been cancelled or the window
            // changed while it ran.
            if let stop = checkpoint(request) { throw Stop(result: stop) }
        }
        request.inFlight = write.part
        request.lastVerified = nil
        let written = switch write {
        case .size(let size): await context.session.setSize(size)
        case .position(let point): await context.session.setPosition(point)
        }
        if case .failure(let failure) = written { throw Stop(result: .failed(failure, lastVerified: request.lastVerified)) }
        switch await context.session.readFrame() {
        case .failure(let failure): throw Stop(result: .failed(failure, lastVerified: request.lastVerified))
        case .success(let frame): if !commit(request, write.part, frame) { throw Stop(result: .interrupted) }
        }
    }

    /// Moves the window to where a window of `size` belongs, when it isn't there.
    private func align(_ context: Context, size: ScreenSize, _ beforeFirstWrite: @Sendable () async -> Void) async throws(Stop) {
        let request = context.request
        let destination = alignedOrigin(request.job, size: size)
        if differs(request.expected.origin, destination) {
            try await perform(.position(destination), context, beforeFirstWrite)
        }
    }

    private func alignedOrigin(_ job: WriteJob, size: ScreenSize) -> ScreenPoint {
        EdgeAligner.origin(
            for: job.target, actualSize: size, visible: job.targetVisible, edges: job.alignment, gap: job.gap
        )
    }

    private func classify(_ job: WriteJob, achieved: ScreenRect) -> WriteResult {
        let target = job.target
        if differs(achieved.origin, alignedOrigin(job, size: achieved.size)) { return .positionRefused(achieved) }
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

    // MARK: Checks

    /// The checks before a write: cancellation and reconfiguration, then frames observed
    /// since the last check.
    private func checkpoint(_ request: Request) -> WriteResult? {
        if Task.isCancelled || epoch != request.startEpoch { return .cancelled(lastVerified: request.lastVerified) }
        return judgePending(request) ? .interrupted : nil
    }

    /// Judges the frames observed since the last check: a frame this request already verified
    /// is its own; any other may differ from the expected frame in the part that was in flight
    /// when it was observed, and in no other.
    /// Returns whether one is an external change.
    private func judgePending(_ request: Request) -> Bool {
        let pending = request.observed
        request.observed = []
        return pending.contains { observation in
            // The start is read back by any write the app refuses, but it isn't a frame this request
            // put there: the window snapping back to it is an external change.
            if differs(observation.frame, request.job.start),
               request.verified.contains(where: { !differs($0, observation.frame) }) { return false }
            let positionMoved = differs(observation.frame.origin, request.expected.origin) && observation.part != .position
            let sizeChanged = differs(observation.frame.size, request.expected.size) && observation.part != .size
            return positionMoved || sizeChanged
        }
    }

    /// Checks a read-back: the part not written must be unchanged or explained by an
    /// adjustment. A pass makes the frame read the expected and last verified one.
    private func commit(_ request: Request, _ part: WritePart, _ read: ScreenRect) -> Bool {
        request.inFlight = nil
        let otherChanged = switch part {
        case .size: differs(read.origin, request.expected.origin)
        case .position: differs(read.size, request.expected.size)
        }
        if otherChanged {
            let adjustmentCase = AdjustmentCase(
                written: part, before: request.expected, after: read,
                targetVisible: request.job.targetVisible, displays: request.job.displays
            )
            guard adjustments.contains(where: { $0.explains(adjustmentCase) }) else { return false }
        }
        request.expected = read
        request.lastVerified = read
        request.lastOwn = read
        request.verified.append(read)
        return true
    }

    private func differs(_ a: ScreenPoint, _ b: ScreenPoint) -> Bool {
        abs(a.x - b.x) > Self.tolerance || abs(a.y - b.y) > Self.tolerance
    }

    private func differs(_ a: ScreenSize, _ b: ScreenSize) -> Bool {
        abs(a.width - b.width) > Self.tolerance || abs(a.height - b.height) > Self.tolerance
    }

    private func differs(_ a: ScreenRect, _ b: ScreenRect) -> Bool {
        !a.isClose(to: b, within: Self.tolerance)
    }
}

private extension WriteResult {
    /// The frame a result carries.
    var frame: ScreenRect? {
        switch self {
        case .placed(let frame), .sizeRefused(let frame), .positionRefused(let frame): frame
        case .interrupted, .failed, .cancelled: nil
        }
    }

    /// A request that ran to the end, as opposed to one that stopped.
    var isAchievement: Bool { frame != nil }
}
