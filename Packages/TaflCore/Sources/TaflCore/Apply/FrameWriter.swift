import Foundation

public struct WriteJob: Sendable {
    /// The request, begun by Resolve's reading of the window.
    public var ticket: RequestTicket
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
    public var firstWrite: FirstWrite

    public var window: WindowHandle { ticket.window }

    public init(
        ticket: RequestTicket,
        appName: String,
        start: ScreenRect,
        target: ScreenRect,
        targetVisible: ScreenRect,
        crossesDisplays: Bool,
        minSize: ScreenSize?,
        displays: [Display],
        alignment: AlignmentEdges = [],
        gap: Double = 0,
        firstWrite: FirstWrite = FirstWrite()
    ) {
        self.ticket = ticket
        self.appName = appName
        self.start = start
        self.target = target
        self.targetVisible = targetVisible
        self.crossesDisplays = crossesDisplays
        self.minSize = minSize
        self.displays = displays
        self.alignment = alignment
        self.gap = gap
        self.firstWrite = firstWrite
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

/// Applies a frame as a sequence of writes, one at a time, each read back. The owner judges every
/// read-back, and every other reading of the window, as it is read: a frame someone else moved
/// interrupts the request, and the writer stops at its next step. One request per window at a time;
/// `WindowRequestQueue` provides that. The writer's result says what it saw itself; a reading the
/// owner judged after the writer's last step reaches the request's end, not this result.
public struct FrameWriter: Sendable {
    /// A size short of the target by less than this, and never larger, counts as success.
    private static let shortfallLimit = 30.0
    private static let tolerance = FrameCheck.tolerance

    /// Where the request has the window, kept between the writer's own steps.
    private final class Progress {
        /// The frame the last read-back found, or the start.
        var expected: ScreenRect
        /// The last frame read back in the current session.
        var lastVerified: ScreenRect?

        init(expected: ScreenRect) {
            self.expected = expected
        }
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

    private struct Context {
        var job: WriteJob
        var session: any WriteSession
        var progress: Progress
    }

    private let platform: any WindowPlatform
    private let clock: any TaflClock
    private let owner: WindowOwner
    private let reapplyDelay: Duration?

    public init(
        platform: any WindowPlatform,
        clock: any TaflClock,
        owner: WindowOwner,
        reapplyDelay: Duration? = .milliseconds(25)
    ) {
        self.platform = platform
        self.clock = clock
        self.owner = owner
        self.reapplyDelay = reapplyDelay
    }

    /// A request already over when Apply begins opens no session.
    public func write(_ job: WriteJob) async -> WriteResult {
        switch owner.checkpoint(job.ticket) {
        case .write: break
        case .interrupted: return .interrupted
        case .cancelled, .declined: return .cancelled(lastVerified: nil)
        }
        let progress = Progress(expected: job.start)
        let first = await attempt(job, progress, reapplying: nil)
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
        guard !Task.isCancelled else { return first }
        switch owner.checkpoint(job.ticket) {
        case .write: break
        // Not reapplied over an external change.
        case .interrupted: return .interrupted
        case .cancelled, .declined: return first
        }
        return await attempt(job, progress, reapplying: first)
    }

    // MARK: The request

    /// One session, from `beginWriting` to `end()`. A reapply (`reapplying` is the earlier result)
    /// first reads the frame: a window that is no longer where that result left it was moved by
    /// someone else.
    private func attempt(_ job: WriteJob, _ progress: Progress, reapplying earlier: WriteResult?) async -> WriteResult {
        progress.lastVerified = nil
        let session: any WriteSession
        switch await platform.beginWriting(job.window) {
        case .failure(let failure):
            return earlier ?? .failed(failure, lastVerified: nil)
        case .success(let opened): session = opened
        }
        let context = Context(job: job, session: session, progress: progress)
        let result: WriteResult
        if let earlier {
            result = await reapply(context, after: earlier)
        } else {
            result = await sequence(context)
        }
        await session.end()
        return result
    }

    private func reapply(_ context: Context, after earlier: WriteResult) async -> WriteResult {
        if Task.isCancelled { return earlier }
        switch owner.checkpoint(context.job.ticket) {
        case .write: break
        case .interrupted: return .interrupted
        case .cancelled, .declined: return earlier
        }
        let owner = owner
        let ticket = context.job.ticket
        switch await context.session.readFrame(take: { owner.readBack(ticket, $0.frame) }) {
        case .failure, .success(.ended): return earlier
        case .success(.interrupted): return .interrupted
        case .success(.own(let frame)): context.progress.expected = frame
        }
        let result = await sequence(context)
        return result == .cancelled(lastVerified: nil) ? earlier : result
    }

    // MARK: The write sequence

    private func sequence(_ context: Context) async -> WriteResult {
        let progress = context.progress
        let job = context.job
        let target = job.target
        let start = progress.expected
        do throws(Stop) {
            let sizeFirst = WriteOrder.sizeFirst(
                from: start, to: target, bounds: job.targetVisible, acrossDisplays: job.crossesDisplays
            )
            let sizeNeeded = differs(start.size, target.size)
            let positionNeeded = differs(start.origin, target.origin)
            if sizeFirst {
                if sizeNeeded {
                    try await perform(.size(target.size), context)
                    // As Rectangle does, place the window as if it had the size it asked for, so a
                    // limit that depends on where the window sits doesn't hold the next write back.
                    let accepted = progress.expected.size
                    let placed = ScreenSize(width: max(accepted.width, target.width), height: max(accepted.height, target.height))
                    try await align(context, size: placed)
                } else if positionNeeded {
                    try await perform(.position(target.origin), context)
                }
            } else {
                if positionNeeded { try await perform(.position(target.origin), context) }
                if sizeNeeded { try await perform(.size(target.size), context) }
            }
            let minimum = job.minSize ?? ScreenSize(width: 0, height: 0)
            let retry = ScreenSize(width: max(target.width, minimum.width), height: max(target.height, minimum.height))
            if differs(progress.expected.size, target.size), differs(progress.expected.size, retry) {
                try await perform(.size(retry), context)
                try await align(context, size: progress.expected.size)
            }
        } catch {
            return error.result
        }
        return classify(job, achieved: progress.expected)
    }

    /// One write: the owner's go-ahead, the write, and its read-back, which the owner checks.
    private func perform(_ write: Write, _ context: Context) async throws(Stop) {
        let progress = context.progress
        let job = context.job
        if Task.isCancelled { throw Stop(result: .cancelled(lastVerified: progress.lastVerified)) }
        let go = owner.willWrite(
            job.ticket, write.part, targetVisible: job.targetVisible, displays: job.displays, firstWrite: job.firstWrite
        )
        switch go {
        case .write: break
        case .interrupted: throw Stop(result: .interrupted)
        case .cancelled, .declined: throw Stop(result: .cancelled(lastVerified: progress.lastVerified))
        }
        progress.lastVerified = nil
        let written = switch write {
        case .size(let size): await context.session.setSize(size)
        case .position(let point): await context.session.setPosition(point)
        }
        if case .failure(let failure) = written {
            owner.writeFailed(job.ticket)
            throw Stop(result: .failed(failure, lastVerified: progress.lastVerified))
        }
        let owner = owner
        let ticket = job.ticket
        switch await context.session.readFrame(take: { owner.readBack(ticket, $0.frame) }) {
        case .failure(let failure):
            owner.writeFailed(ticket)
            throw Stop(result: .failed(failure, lastVerified: progress.lastVerified))
        case .success(.own(let frame)):
            progress.expected = frame
            progress.lastVerified = frame
        case .success(.interrupted):
            throw Stop(result: .interrupted)
        case .success(.ended):
            throw Stop(result: .cancelled(lastVerified: progress.lastVerified))
        }
    }

    /// Moves the window to where a window of `size` belongs, when it isn't there.
    private func align(_ context: Context, size: ScreenSize) async throws(Stop) {
        let destination = alignedOrigin(context.job, size: size)
        if differs(context.progress.expected.origin, destination) {
            try await perform(.position(destination), context)
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

    private func differs(_ a: ScreenPoint, _ b: ScreenPoint) -> Bool {
        FrameCheck.differs(a, b)
    }

    private func differs(_ a: ScreenSize, _ b: ScreenSize) -> Bool {
        FrameCheck.differs(a, b)
    }
}
