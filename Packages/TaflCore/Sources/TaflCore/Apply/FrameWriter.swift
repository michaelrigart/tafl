import Foundation

public struct WriteJob: Sendable {
    public var window: WindowHandle
    public var appName: String
    public var start: ScreenRect
    /// When `start` was read.
    public var startReadAt: ContinuousClock.Instant
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
        startReadAt: ContinuousClock.Instant,
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
        self.startReadAt = startReadAt
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
    /// Read before the newest reading Tafl has accepted for the window: it says nothing.
    case stale
    /// A request for the window is under way, from Resolve's read on; the frame was kept and is
    /// judged against it.
    case heldForWrite
    /// Within a point of the window's newest accepted frame.
    case unchanged
    /// Somewhere else, or the first frame Tafl has of the window: someone else moved it.
    case external
}

/// What Resolve's reading of a window says as its request begins.
public enum RequestStart: Equatable, Sendable {
    /// Where Tafl last had the window, or the first frame Tafl has of it.
    case unchanged
    /// Somewhere else than Tafl last had it: someone moved the window.
    case moved
    /// A newer reading, at another frame, came first: the window moved during the placement, and
    /// the request writes nothing.
    case overtaken
}

/// Applies a frame as a sequence of checked writes: each write is read back and the part it
/// did not set must be unchanged (or explained by a named macOS adjustment), otherwise
/// something else moved the window and the request stops. One request per window at a time;
/// `WindowRequestQueue` provides that.
///
/// Every reading of a window is judged against the newest Tafl has accepted for it, which the
/// writer shares with the memory keeper: an older one says nothing. A request takes part from
/// Resolve's read (`begin`) until it ends (`end`): frames read for its window meanwhile are held
/// and judged against it.
public actor FrameWriter {
    /// A size short of the target by less than this, and never larger, counts as success.
    private static let shortfallLimit = 30.0
    private static let tolerance = 1.0

    private struct PendingFrame {
        var frame: ScreenRect
        var readAt: ContinuousClock.Instant
        /// The part in flight when the frame was observed.
        var part: WritePart?
    }

    /// Everything a request knows about its window, from Resolve's read until it ends.
    private final class Request {
        let start: FrameReading
        /// The reconfiguration epoch the write started in.
        var startEpoch = 0
        /// Frames observed since the last check, kept across sessions.
        var observed: [PendingFrame] = []
        /// Every frame read back and verified in this request, in any session: a notification
        /// for one of them that is read late is still Tafl's own.
        var verified: [ScreenRect] = []
        /// The last frame read back that passed its check, in any session.
        var lastOwn: ScreenRect?
        /// The newest reading the request rests on: its start, a read-back, or a held frame that
        /// showed the window moved.
        var latest: WindowReadings.Newest
        // The current session's.
        var expected: ScreenRect
        var inFlight: WritePart?
        var lastVerified: ScreenRect?
        var awaitingFirstWrite = true

        init(start: FrameReading) {
            self.start = start
            expected = start.frame
            latest = WindowReadings.Newest(readAt: start.readAt, frame: start.frame)
        }

        func beginSession(from start: ScreenRect) {
            expected = start
            inFlight = nil
            lastVerified = nil
            awaitingFirstWrite = true
        }

        /// A reading of the request's own: what it rests on from now.
        func read(_ reading: FrameReading) {
            latest = WindowReadings.Newest(readAt: max(latest.readAt, reading.readAt), frame: reading.frame)
        }
    }

    private struct Context {
        var request: Request
        var job: WriteJob
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
    private let readings: WindowReadings
    private var requests: [WindowHandle: Request] = [:]

    /// Bumped when a display reconfiguration begins; a write that started earlier is cancelled.
    public private(set) var epoch = 0

    public init(
        platform: any WindowPlatform,
        clock: any TaflClock,
        adjustments: [MacOSAdjustment],
        reapplyDelay: Duration? = .milliseconds(25)
    ) {
        self.init(
            platform: platform, clock: clock, adjustments: adjustments, reapplyDelay: reapplyDelay,
            readings: WindowReadings()
        )
    }

    init(
        platform: any WindowPlatform,
        clock: any TaflClock,
        adjustments: [MacOSAdjustment],
        reapplyDelay: Duration? = .milliseconds(25),
        readings: WindowReadings
    ) {
        self.platform = platform
        self.clock = clock
        self.adjustments = adjustments
        self.reapplyDelay = reapplyDelay
        self.readings = readings
    }

    // MARK: Requests

    /// Begins a request for the window at Resolve's read. Unless the request is overtaken, frames
    /// read for the window are held for it from now until `end`.
    public func begin(_ window: WindowHandle, start: FrameReading) -> RequestStart {
        register(window, start: start).start
    }

    private func register(_ window: WindowHandle, start: FrameReading) -> (start: RequestStart, request: Request?) {
        let judgement = readings.judge(window, start)
        if judgement == .stale, let newest = readings.newest(window)?.frame, differs(newest, start.frame) {
            return (.overtaken, nil)
        }
        let request = Request(start: start)
        requests[window] = request
        return (judgement == .moved ? .moved : .unchanged, request)
    }

    /// `beforeFirstWrite` runs once the request is under way, just before its first write; when it
    /// answers false the request stops with nothing written. However the request ends (placed,
    /// failed or cancelled), the frames held for it meanwhile are judged before the result is:
    /// an external change among them makes the result `.interrupted`. `readAt` is when the newest
    /// reading the result rests on was taken. A write for a window no request was begun for begins
    /// and ends one itself.
    public func write(
        _ job: WriteJob,
        beforeFirstWrite: @Sendable () async -> Bool
    ) async -> (result: WriteResult, readAt: ContinuousClock.Instant) {
        let window = job.window
        let start = FrameReading(frame: job.start, readAt: job.startReadAt)
        let request: Request
        let begunHere: Bool
        if let begun = requests[window], begun.start == start {
            request = begun
            begunHere = false
        } else {
            guard let registered = register(window, start: start).request else { return (.interrupted, start.readAt) }
            request = registered
            begunHere = true
        }
        var result: WriteResult = .cancelled(lastVerified: nil)
        if job.plannedEpoch.map({ $0 == epoch }) ?? true {
            request.startEpoch = epoch
            result = await run(request, job, beforeFirstWrite)
            if judgePending(request) { result = .interrupted }
        }
        if begunHere { finish(window, request) }
        return (result, request.latest.readAt)
    }

    /// Ends the window's request. The frames held since its last check are judged against where it
    /// left the window, and what it rests on becomes the window's newest reading. Returns the newest
    /// of those frames when one shows that someone moved the window.
    @discardableResult
    public func end(_ window: WindowHandle) -> FrameReading? {
        guard let request = requests[window] else { return nil }
        return finish(window, request)
    }

    /// Ends the request, unless another has taken the window's place since.
    @discardableResult
    private func finish(_ window: WindowHandle, _ request: Request) -> FrameReading? {
        guard requests[window] === request else { return nil }
        requests[window] = nil
        var moved: FrameReading?
        for pending in request.observed where pending.readAt >= request.latest.readAt {
            if let frame = request.latest.frame, differs(frame, pending.frame) {
                moved = FrameReading(frame: pending.frame, readAt: pending.readAt)
            }
            request.read(FrameReading(frame: pending.frame, readAt: pending.readAt))
        }
        request.observed = []
        readings.settle(window, request.latest)
        return moved
    }

    /// Decides in one step what a frame read for this window is: `.stale` when it was read before
    /// the window's newest accepted reading, else `.heldForWrite` while a request for it is under
    /// way, else `.unchanged` when it is within a point of the newest frame, else `.external`.
    /// Outside a request, a frame that is not stale becomes the newest.
    public func observe(_ window: WindowHandle, frame: ScreenRect, readAt: ContinuousClock.Instant) -> FrameObservation {
        if let request = requests[window] {
            guard readings.accepts(window, readAt: readAt) else { return .stale }
            request.observed.append(PendingFrame(frame: frame, readAt: readAt, part: request.inFlight))
            return .heldForWrite
        }
        switch readings.judge(window, FrameReading(frame: frame, readAt: readAt)) {
        case .stale: return .stale
        case .unchanged: return .unchanged
        case .moved, .unseen: return .external
        }
    }

    /// Takes the frame a window was announced at as the first Tafl has of it.
    public func firstSeen(_ window: WindowHandle, _ reading: FrameReading) {
        readings.firstSeen(window, reading)
    }

    /// Drops what Tafl read of a window that is gone.
    public func forget(_ window: WindowHandle) {
        readings.forget(window)
    }

    /// Drops what Tafl read of an app's windows, for an app that quit.
    public func forget(pid: Int32) {
        readings.forget(pid: pid)
    }

    /// True while a request for this window is under way, from Resolve's read until it ends.
    public func isWriting(_ window: WindowHandle) -> Bool {
        requests[window] != nil
    }

    public func reconfigurationBegan() {
        epoch += 1
    }

    // MARK: The request

    private func run(_ request: Request, _ job: WriteJob, _ beforeFirstWrite: @Sendable () async -> Bool) async -> WriteResult {
        let first = await attempt(request, job, start: job.start, reapplying: nil, beforeFirstWrite)
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
            return first
        }
        guard !Task.isCancelled, epoch == request.startEpoch else { return first }
        // Not reapplied over an external change.
        if judgePending(request) { return .interrupted }
        return await attempt(request, job, start: frame, reapplying: first, { true })
    }

    /// One session, from `beginWriting` to `end()`. A reapply (`reapplying` is the earlier
    /// result) first reads the frame: a window that is no longer where that result left it
    /// was moved by someone else.
    private func attempt(
        _ request: Request,
        _ job: WriteJob,
        start: ScreenRect,
        reapplying earlier: WriteResult?,
        _ beforeFirstWrite: @Sendable () async -> Bool
    ) async -> WriteResult {
        request.beginSession(from: start)
        let session: any WriteSession
        switch await platform.beginWriting(job.window) {
        case .failure(let failure):
            return earlier ?? .failed(failure, lastVerified: nil)
        case .success(let opened): session = opened
        }
        let context = Context(request: request, job: job, session: session)

        let result: WriteResult
        if let earlier {
            result = await reapply(context, after: earlier, beforeFirstWrite)
        } else {
            result = await sequence(context, beforeFirstWrite)
        }
        await session.end()
        return result
    }

    private func reapply(
        _ context: Context,
        after earlier: WriteResult,
        _ beforeFirstWrite: @Sendable () async -> Bool
    ) async -> WriteResult {
        let request = context.request
        if Task.isCancelled || epoch != request.startEpoch { return earlier }
        guard case .success(let read) = await context.session.readFrame(take: { $0 }) else { return earlier }
        request.read(read)
        if differs(read.frame, request.expected) { return .interrupted }
        let result = await sequence(context, beforeFirstWrite)
        return result == .cancelled(lastVerified: nil) ? earlier : result
    }

    // MARK: The write sequence

    private func sequence(_ context: Context, _ beforeFirstWrite: @Sendable () async -> Bool) async -> WriteResult {
        let request = context.request
        let job = context.job
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
        _ beforeFirstWrite: @Sendable () async -> Bool
    ) async throws(Stop) {
        let request = context.request
        if let stop = checkpoint(request) { throw Stop(result: stop) }
        if request.awaitingFirstWrite {
            request.awaitingFirstWrite = false
            guard await beforeFirstWrite() else { throw Stop(result: .cancelled(lastVerified: request.lastVerified)) }
            // The callback is a suspension point: the request may have been cancelled or the window
            // changed while it ran.
            if let stop = checkpoint(request) { throw Stop(result: stop) }
        }
        request.inFlight = write.part
        request.lastVerified = nil
        // Until the write is read back, where the window is is not known.
        request.latest.frame = nil
        let written = switch write {
        case .size(let size): await context.session.setSize(size)
        case .position(let point): await context.session.setPosition(point)
        }
        if case .failure(let failure) = written { throw Stop(result: .failed(failure, lastVerified: request.lastVerified)) }
        switch await context.session.readFrame(take: { $0 }) {
        case .failure(let failure): throw Stop(result: .failed(failure, lastVerified: request.lastVerified))
        case .success(let read):
            request.read(read)
            if !commit(request, context.job, write.part, read.frame) { throw Stop(result: .interrupted) }
        }
    }

    /// Moves the window to where a window of `size` belongs, when it isn't there.
    private func align(_ context: Context, size: ScreenSize, _ beforeFirstWrite: @Sendable () async -> Bool) async throws(Stop) {
        let destination = alignedOrigin(context.job, size: size)
        if differs(context.request.expected.origin, destination) {
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
    /// when it was observed, and in no other. The request then rests on the newest of them, and
    /// on its frame too when one was an external change.
    /// Returns whether one is an external change.
    private func judgePending(_ request: Request) -> Bool {
        let pending = request.observed
        request.observed = []
        let external = pending.contains { observation in
            // The start is read back by any write the app refuses, but it isn't a frame this request
            // put there: the window snapping back to it is an external change.
            if differs(observation.frame, request.start.frame),
               request.verified.contains(where: { !differs($0, observation.frame) }) { return false }
            let positionMoved = differs(observation.frame.origin, request.expected.origin) && observation.part != .position
            let sizeChanged = differs(observation.frame.size, request.expected.size) && observation.part != .size
            return positionMoved || sizeChanged
        }
        if let newest = pending.max(by: { $0.readAt < $1.readAt }) {
            if external {
                request.read(FrameReading(frame: newest.frame, readAt: newest.readAt))
            } else {
                request.latest.readAt = max(request.latest.readAt, newest.readAt)
            }
        }
        return external
    }

    /// Checks a read-back: the part not written must be unchanged or explained by an
    /// adjustment. A pass makes the frame read the expected and last verified one.
    private func commit(_ request: Request, _ job: WriteJob, _ part: WritePart, _ read: ScreenRect) -> Bool {
        request.inFlight = nil
        let otherChanged = switch part {
        case .size: differs(read.origin, request.expected.origin)
        case .position: differs(read.size, request.expected.size)
        }
        if otherChanged {
            let adjustmentCase = AdjustmentCase(
                written: part, before: request.expected, after: read,
                targetVisible: job.targetVisible, displays: job.displays
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

