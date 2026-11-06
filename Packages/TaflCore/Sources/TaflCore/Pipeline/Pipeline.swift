import Foundation

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

/// What the stages after Resolve's reading came to, for Record.
private enum Applied {
    /// Stopped before writing, by Resolve or by the plan: nothing to record.
    case stopped(PlacementOutcome)
    /// The window is already where the request puts it.
    case unchanged(MoveRequest, frame: ScreenRect, display: Display)
    /// Apply ran.
    case wrote(WriteResult, MoveRequest, displays: [Display], fallback: Display)
}

/// Resolve, Calculate, Adjust, Apply, Record: every window move runs through here. The stages
/// run inside the window's queue, so planning sees the frame left by an earlier request. The
/// request runs through the window's owner: Resolve's reading begins it, and its end records the
/// outcome in the owner's same step.
public actor Pipeline {
    private static let tolerance = 1.0

    private let platform: any WindowPlatform
    private let writer: FrameWriter
    private let queue: WindowRequestQueue
    private let owner: WindowOwner
    private let steps: [any AdjustStep]

    public init(
        platform: any WindowPlatform,
        writer: FrameWriter,
        queue: WindowRequestQueue,
        owner: WindowOwner,
        steps: [any AdjustStep]
    ) {
        self.platform = platform
        self.writer = writer
        self.queue = queue
        self.owner = owner
        self.steps = steps
    }

    public func run(
        _ window: WindowHandle,
        config: Config,
        unplaceable: Unplaceable = .skipped,
        plan: @escaping @Sendable (ResolvedWindow) -> PlanResult
    ) async -> PlacementOutcome {
        let outcome = await queue.run(window) { [self] in
            await execute(window, config: config, unplaceable: unplaceable, plan: plan)
        }
        return outcome ?? .superseded
    }

    public func run(_ request: MoveRequest, config: Config) async -> PlacementOutcome {
        let unplaceable: Unplaceable = if case .action = request.source { .explained } else { .skipped }
        return await run(request.window, config: config, unplaceable: unplaceable) { _ in .request(request) }
    }

    // MARK: Stages

    private func execute(
        _ window: WindowHandle,
        config: Config,
        unplaceable: Unplaceable,
        plan: @Sendable (ResolvedWindow) -> PlanResult
    ) async -> PlacementOutcome {
        let owner = owner
        let snapshot: WindowSnapshot
        let start: RequestStart
        switch await platform.snapshot(of: window, take: { ($0, owner.beginRequest($0)) }) {
        case .failure(let failure): return .failed(await failureKind(failure, window: window, appName: nil))
        case .success(let read): (snapshot, start) = read
        }
        let applied = await proceed(snapshot, start, config: config, unplaceable: unplaceable, plan: plan)
        let ending = owner.endRequest(start.ticket) { ending, placement in
            Self.record(applied, ending, &placement)
        }
        return await outcome(of: applied, ending, snapshot: snapshot)
    }

    /// The stages after Resolve's reading.
    private func proceed(
        _ snapshot: WindowSnapshot,
        _ start: RequestStart,
        config: Config,
        unplaceable: Unplaceable,
        plan: @Sendable (ResolvedWindow) -> PlanResult
    ) async -> Applied {
        let resolved: ResolvedWindow
        switch await resolve(snapshot, start.placement, unplaceable: unplaceable) {
        case .failed(let kind): return .stopped(.failed(kind))
        case .skipped: return .stopped(.skipped)
        case .resolved(let value): resolved = value
        }
        let request: MoveRequest
        switch plan(resolved) {
        case .nothing: return .stopped(.unchanged)
        case .fail(let kind): return .stopped(.failed(kind))
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
            return .unchanged(request, frame: snapshot.frame, display: resolved.display)
        }

        let job = WriteJob(
            ticket: start.ticket,
            appName: snapshot.appName,
            start: snapshot.frame,
            target: adjusted.rect,
            targetVisible: target.visibleFrame,
            crossesDisplays: crosses,
            minSize: snapshot.minSize,
            displays: resolved.displays,
            alignment: PlacementCalculator.alignment(of: request.spec, adjusted),
            gap: context.gap,
            firstWrite: FirstWrite(
                opensChainOn: request.source.countsForRestore ? resolved.display : nil,
                yieldsToTouch: request.source.yieldsToTouch
            )
        )
        let result = await writer.write(job)
        return .wrote(result, request, displays: resolved.displays, fallback: target)
    }

    /// Resolve: the window's display, and where Tafl placed it, as of Resolve's reading.
    private func resolve(_ snapshot: WindowSnapshot, _ placement: WindowPlacement, unplaceable: Unplaceable) async -> Resolution {
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
        return .resolved(ResolvedWindow(
            snapshot: snapshot,
            display: current,
            displays: displays,
            placed: placement.placed,
            isAtAchieved: placement.isAtAchievedFrame(snapshot.frame),
            restoreTarget: placement.restoreTarget(current: current, displays: displays)
        ))
    }

    /// Record: keeps the window's placement in step with what the request did, in the owner's step
    /// that ends it. An interruption was recorded by the reading that showed it, and stands.
    private static func record(_ applied: Applied, _ ending: RequestEnding, _ placement: inout WindowPlacement) {
        guard !ending.interrupted else { return }
        switch applied {
        case .stopped:
            return
        case .unchanged(let request, let frame, let display):
            // A request whose target is where the window already is: the window counts as placed by
            // it, and a restore that is already done completes. A display change leaves it alone.
            guard request.source != .displayChange else { return }
            if request.source.countsForRestore { placement.openChain(before: frame, on: display) }
            placement.recordPlaced(placedRecord(request, achieved: frame, display: display.identity))
            if request.source.completesRestore { placement.completeRestore() }
        case .wrote(let result, let request, let displays, let fallback):
            func display(of frame: ScreenRect) -> DisplayIdentity {
                (DisplayLocator.display(containing: frame, in: displays) ?? fallback).identity
            }
            switch result {
            case .placed(let achieved), .sizeRefused(let achieved), .positionRefused(let achieved):
                placement.recordPlaced(placedRecord(request, achieved: achieved, display: display(of: achieved)))
                if request.source.completesRestore, result == .placed(achieved) { placement.completeRestore() }
            case .interrupted:
                return
            case .cancelled(let verified):
                if let verified { placement.recordPlaced(ownRecord(verified, display: display(of: verified))) }
            case .failed(_, let verified):
                if let verified {
                    placement.recordPlaced(ownRecord(verified, display: display(of: verified)))
                } else if ending.wrote {
                    // Nothing verified after a write: the window is no longer at the old record, but
                    // nothing external happened, so the chain stays open.
                    placement.placed = nil
                }
            }
        }
    }

    private static func placedRecord(_ request: MoveRequest, achieved: ScreenRect, display: DisplayIdentity) -> PlacedRecord {
        PlacedRecord(
            action: request.source.action,
            layout: request.source.layoutName,
            placement: request.placement,
            cycleStep: request.cycleStep,
            achieved: achieved,
            display: display
        )
    }

    /// A frame verified before a request stopped is Tafl's own, though nothing repeats from it.
    private static func ownRecord(_ frame: ScreenRect, display: DisplayIdentity) -> PlacedRecord {
        PlacedRecord(action: nil, layout: nil, placement: nil, cycleStep: 0, achieved: frame, display: display)
    }

    /// The outcome a request reports. One that reached Apply and was interrupted was moved during
    /// placement, whatever the writer saw.
    private func outcome(of applied: Applied, _ ending: RequestEnding, snapshot: WindowSnapshot) async -> PlacementOutcome {
        switch applied {
        case .stopped(let outcome):
            return outcome
        case .unchanged:
            return .unchanged
        case .wrote(let result, _, _, _):
            if ending.interrupted { return .failed(.movedDuringPlacement) }
            switch result {
            case .placed(let achieved): return .placed(achieved)
            case .sizeRefused: return .failed(.sizeRefused(app: snapshot.appName))
            case .positionRefused: return .failed(.cannotMove)
            case .interrupted: return .failed(.movedDuringPlacement)
            case .cancelled: return .superseded
            case .failed(let failure, _):
                return .failed(await failureKind(failure, window: snapshot.handle, appName: snapshot.appName))
            }
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
