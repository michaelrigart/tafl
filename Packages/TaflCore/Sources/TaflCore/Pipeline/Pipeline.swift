import Foundation
import Synchronization

public enum PlacementOutcome: Equatable, Sendable {
    case placed(ScreenRect)
    case unchanged
    case failed(FailureKind)
    /// A newer request for the window, or a display reconfiguration, cancelled this one.
    case superseded
    /// The window stopped being placeable before it was written: nothing was done or recorded.
    case skipped
}

/// What a request does with a window that can't be placed: full screen, minimised, in a hidden
/// app, or a sheet.
public enum Unplaceable: Sendable {
    /// A user's action on the focused window says why for full screen and a sheet; a minimised
    /// window or a hidden app's is skipped.
    case explained
    /// A run skips the window: no failure, no overlay, nothing recorded.
    case skipped
}

/// What Resolve reads for a window, handed to the planner.
public struct ResolvedWindow: Sendable {
    public var snapshot: WindowSnapshot
    /// The display the window is on now.
    public var display: Display
    public var displays: [Display]
    public var placed: PlacedRecord?
    /// Whether the window is still where `placed` left it.
    public var isAtAchieved: Bool
    public var restoreTarget: (frame: ScreenRect, display: Display)?

    public init(
        snapshot: WindowSnapshot,
        display: Display,
        displays: [Display],
        placed: PlacedRecord?,
        isAtAchieved: Bool,
        restoreTarget: (frame: ScreenRect, display: Display)?
    ) {
        self.snapshot = snapshot
        self.display = display
        self.displays = displays
        self.placed = placed
        self.isAtAchieved = isAtAchieved
        self.restoreTarget = restoreTarget
    }
}

private enum Resolution {
    case resolved(ResolvedWindow)
    case failed(FailureKind)
    case skipped
}

public enum PlanResult: Sendable {
    case request(MoveRequest)
    case nothing
    case fail(FailureKind)
}

/// Resolve, Calculate, Adjust, Apply, Record: every window move runs through here. The stages
/// run inside the window's queue, so planning sees the frame left by an earlier request.
public actor Pipeline {
    private static let tolerance = 1.0

    private let platform: any WindowPlatform
    private let writer: FrameWriter
    private let queue: WindowRequestQueue
    private let memory: MemoryKeeper
    private let steps: [any AdjustStep]

    public init(
        platform: any WindowPlatform,
        writer: FrameWriter,
        queue: WindowRequestQueue,
        memory: MemoryKeeper,
        steps: [any AdjustStep]
    ) {
        self.platform = platform
        self.writer = writer
        self.queue = queue
        self.memory = memory
        self.steps = steps
    }

    /// `eligible` is asked after Resolve, just before the first write: a placement that is no longer
    /// wanted then writes nothing and comes back superseded. `moved` runs as soon as a reading the
    /// request takes part in shows that someone else moved the window: Resolve's own, or one read
    /// after it that the request did not write over. `landed` runs inside the window's request
    /// once its outcome is known, with when the newest reading the outcome rests on was taken (nil
    /// when the window could not be read), so what it records comes before anything the window's
    /// next request records.
    public func run(
        _ window: WindowHandle,
        config: Config,
        unplaceable: Unplaceable = .skipped,
        plan: @escaping @Sendable (ResolvedWindow) -> PlanResult,
        eligible: @escaping @Sendable () async -> Bool = { true },
        moved: @escaping @Sendable () async -> Void = {},
        landed: @escaping @Sendable (PlacementOutcome, ContinuousClock.Instant?) async -> Void = { _, _ in }
    ) async -> PlacementOutcome {
        let outcome = await queue.run(window) { [self] in
            let (outcome, readAt) = await execute(
                window, config: config, unplaceable: unplaceable, plan: plan, eligible: eligible, moved: moved
            )
            await landed(outcome, readAt)
            return outcome
        }
        return outcome ?? .superseded
    }

    public func run(_ request: MoveRequest, config: Config) async -> PlacementOutcome {
        let unplaceable: Unplaceable = if case .action = request.source { .explained } else { .skipped }
        return await run(request.window, config: config, unplaceable: unplaceable) { _ in .request(request) }
    }

    // MARK: Stages

    /// The outcome, and when the newest reading it rests on was taken. The request takes part from
    /// Resolve's read: frames read for the window from then on are held for it until it ends.
    private func execute(
        _ window: WindowHandle,
        config: Config,
        unplaceable: Unplaceable,
        plan: @Sendable (ResolvedWindow) -> PlanResult,
        eligible: @Sendable () async -> Bool,
        moved: @Sendable () async -> Void
    ) async -> (PlacementOutcome, ContinuousClock.Instant?) {
        // Read first: a reconfiguration that begins after this cancels the write.
        let epoch = await writer.epoch
        let snapshot: WindowSnapshot
        switch await platform.snapshot(of: window, take: { $0 }) {
        case .failure(let failure): return (.failed(await failureKind(failure, window: window, appName: nil)), nil)
        case .success(let value): snapshot = value
        }
        switch await writer.begin(window, start: FrameReading(frame: snapshot.frame, readAt: snapshot.readAt)) {
        case .overtaken:
            return (.failed(.movedDuringPlacement), snapshot.readAt)
        case .moved:
            await memory.recordPlacement(window, readAt: snapshot.readAt) { $0.recordExternalChange() }
            await moved()
        case .unchanged:
            break
        }
        let outcome = await proceed(
            snapshot, epoch: epoch, config: config, unplaceable: unplaceable, plan: plan, eligible: eligible
        )
        if let after = await writer.end(window) {
            await memory.recordPlacement(window, readAt: after.readAt) { $0.recordExternalChange() }
            await moved()
        }
        return outcome
    }

    /// The stages after Resolve's read.
    private func proceed(
        _ snapshot: WindowSnapshot,
        epoch: Int,
        config: Config,
        unplaceable: Unplaceable,
        plan: @Sendable (ResolvedWindow) -> PlanResult,
        eligible: @Sendable () async -> Bool
    ) async -> (PlacementOutcome, ContinuousClock.Instant?) {
        let window = snapshot.handle
        let resolved: ResolvedWindow
        switch await resolve(snapshot, unplaceable: unplaceable) {
        case .failed(let kind): return (.failed(kind), snapshot.readAt)
        case .skipped: return (.skipped, snapshot.readAt)
        case .resolved(let value): resolved = value
        }
        let request: MoveRequest
        switch plan(resolved) {
        case .nothing: return (.unchanged, snapshot.readAt)
        case .fail(let kind): return (.failed(kind), snapshot.readAt)
        case .request(let planned): request = planned
        }

        let target = resolved.displays.first { $0.identity == request.display } ?? resolved.display
        let calculated = PlacementCalculator.calculate(request.spec, window: snapshot.frame, on: target)
        let context = AdjustContext(
            visible: target.visibleFrame,
            gap: request.spec.appliesGap ? config.gap : 0,
            minSize: snapshot.minSize,
            spec: request.spec
        )
        let adjusted = steps.reduce(calculated) { $1.adjust($0, context) }

        let crosses = target.identity != resolved.display.identity
        if !crosses, adjusted.rect.isClose(to: snapshot.frame, within: Self.tolerance) {
            await recordUnchanged(request, resolved)
            return (.unchanged, snapshot.readAt)
        }

        let job = WriteJob(
            window: window,
            appName: snapshot.appName,
            start: snapshot.frame,
            startReadAt: snapshot.readAt,
            target: adjusted.rect,
            targetVisible: target.visibleFrame,
            crossesDisplays: crosses,
            minSize: snapshot.minSize,
            displays: resolved.displays,
            alignment: PlacementCalculator.alignment(of: request.spec, adjusted),
            gap: context.gap,
            plannedEpoch: epoch
        )
        let opensChain = request.source.countsForRestore
        let keeper = memory
        let current = resolved.display
        // Set once the writer is about to write: from then on the window may no longer be where
        // the old placed record says.
        let writing = Mutex(false)
        let (result, readAt) = await writer.write(job) {
            guard await eligible() else { return false }
            writing.withLock { $0 = true }
            if opensChain {
                await keeper.recordPlacement(window, readAt: snapshot.readAt) {
                    $0.openChain(before: snapshot.frame, on: current)
                }
            }
            return true
        }
        let outcome = await record(
            result, readAt: readAt, for: request, snapshot: snapshot, displays: resolved.displays, fallback: target,
            wrote: writing.withLock { $0 }
        )
        return (outcome, readAt)
    }

    /// Resolve: the window's display, and the memory about it, reconciled with where the window is.
    private func resolve(_ snapshot: WindowSnapshot, unplaceable: Unplaceable) async -> Resolution {
        let window = snapshot.handle
        // The predicate the runs enumerate with, for every request, before anything is recorded.
        if !snapshot.isPlaceable {
            if unplaceable == .explained, snapshot.isFullscreen { return .failed(.fullscreen) }
            if unplaceable == .explained, snapshot.isSheet { return .failed(.cannotMove) }
            return .skipped
        }
        if !snapshot.canMove { return .failed(.cannotMove) }
        let displays = await platform.displays()
        guard let current = DisplayLocator.display(containing: snapshot.frame, in: displays) else {
            return .failed(.cannotMove)
        }
        // A window that has left the frame Tafl put it in was moved by something Tafl did not see.
        await memory.recordPlacement(window, readAt: snapshot.readAt) { placement in
            if placement.placed != nil, !placement.isAtAchievedFrame(snapshot.frame) {
                placement.recordExternalChange()
            }
        }
        let known = await memory.read()
        return .resolved(ResolvedWindow(
            snapshot: snapshot,
            display: current,
            displays: displays,
            placed: known.placed[window],
            isAtAchieved: known.isAtAchievedFrame(window, frame: snapshot.frame),
            restoreTarget: known.restoreTarget(window, current: current, displays: displays)
        ))
    }

    /// Record: keeps the memory in step with what Apply did, and maps the result to an outcome.
    /// Every change rests on the newest reading the write took, at `readAt`.
    private func record(
        _ result: WriteResult,
        readAt: ContinuousClock.Instant,
        for request: MoveRequest,
        snapshot: WindowSnapshot,
        displays: [Display],
        fallback: Display,
        wrote: Bool
    ) async -> PlacementOutcome {
        let window = request.window
        func display(of frame: ScreenRect) -> DisplayIdentity {
            (DisplayLocator.display(containing: frame, in: displays) ?? fallback).identity
        }
        switch result {
        case .placed(let achieved), .sizeRefused(let achieved), .positionRefused(let achieved):
            let record = PlacedRecord(
                action: request.source.action,
                layout: request.source.layoutName,
                placement: request.placement,
                cycleStep: request.cycleStep,
                achieved: achieved,
                display: display(of: achieved)
            )
            let completesRestore = request.source.completesRestore && result == .placed(achieved)
            await memory.recordPlacement(window, readAt: readAt) { placement in
                placement.recordPlaced(record)
                if completesRestore { placement.completeRestore() }
            }
            switch result {
            case .sizeRefused: return .failed(.sizeRefused(app: snapshot.appName))
            case .positionRefused: return .failed(.cannotMove)
            default: return .placed(achieved)
            }
        case .interrupted:
            await memory.recordPlacement(window, readAt: readAt) { $0.recordExternalChange() }
            return .failed(.movedDuringPlacement)
        case .cancelled(let verified):
            if let verified { await recordOwn(verified, window, display: display(of: verified), readAt: readAt) }
            return .superseded
        case .failed(let failure, let verified):
            if let verified {
                await recordOwn(verified, window, display: display(of: verified), readAt: readAt)
            } else if wrote {
                // Nothing verified after a write: the window is no longer at the old record, but
                // nothing external happened, so the chain stays open.
                await memory.recordPlacement(window, readAt: readAt) { $0.placed = nil }
            }
            return .failed(await failureKind(failure, window: window, appName: snapshot.appName))
        }
    }

    /// A frame verified before a request stopped is Tafl's own, though nothing repeats from it.
    private func recordOwn(
        _ frame: ScreenRect,
        _ window: WindowHandle,
        display: DisplayIdentity,
        readAt: ContinuousClock.Instant
    ) async {
        let record = PlacedRecord(
            action: nil, layout: nil, placement: nil, cycleStep: 0, achieved: frame, display: display
        )
        await memory.recordPlacement(window, readAt: readAt) { $0.recordPlaced(record) }
    }

    /// A request whose target is where the window already is: the window counts as placed by it,
    /// and a restore that is already done completes. A display change leaves the memory alone.
    private func recordUnchanged(_ request: MoveRequest, _ resolved: ResolvedWindow) async {
        guard request.source != .displayChange else { return }
        let window = request.window
        let frame = resolved.snapshot.frame
        let record = PlacedRecord(
            action: request.source.action,
            layout: request.source.layoutName,
            placement: request.placement,
            cycleStep: request.cycleStep,
            achieved: frame,
            display: resolved.display.identity
        )
        let opensChain = request.source.countsForRestore
        let completesRestore = request.source.completesRestore
        await memory.recordPlacement(window, readAt: resolved.snapshot.readAt) { placement in
            if opensChain { placement.openChain(before: frame, on: resolved.display) }
            placement.recordPlaced(record)
            if completesRestore { placement.completeRestore() }
        }
    }

    private func failureKind(_ failure: PlatformFailure, window: WindowHandle, appName: String?) async -> FailureKind {
        switch failure {
        case .noWindow: return .noWindow
        case .cannotMove: return .cannotMove
        case .fullscreen: return .fullscreen
        case .notResponding:
            if let appName { return .notResponding(app: appName) }
            // The window could not be read, so the app's name comes from the platform by pid.
            return .notResponding(app: await platform.appName(pid: window.pid) ?? "The app")
        }
    }
}

private extension RequestSource {
    var action: Action? {
        switch self {
        case .action(let action): action
        case .layout, .newWindow, .displayChange: nil
        }
    }

    var layoutName: String? {
        switch self {
        case .layout(let name), .newWindow(let name): name
        case .action, .displayChange: nil
        }
    }

    var completesRestore: Bool {
        self == .action(.restore)
    }
}
