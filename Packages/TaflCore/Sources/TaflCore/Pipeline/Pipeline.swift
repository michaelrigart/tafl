import Foundation
import Synchronization

public enum PlacementOutcome: Equatable, Sendable {
    case placed(ScreenRect)
    case unchanged
    case failed(FailureKind)
    /// A newer request for the window, or a display reconfiguration, cancelled this one.
    case superseded
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
    /// wanted then writes nothing and comes back superseded. `landed` runs inside the window's
    /// request once its outcome is known, so what it records comes before anything the window's
    /// next request, or a frame read after it, records.
    public func run(
        _ window: WindowHandle,
        config: Config,
        plan: @escaping @Sendable (ResolvedWindow) -> PlanResult,
        eligible: @escaping @Sendable () async -> Bool = { true },
        landed: @escaping @Sendable (PlacementOutcome) async -> Void = { _ in }
    ) async -> PlacementOutcome {
        let outcome = await queue.run(window) { [self] in
            let outcome = await execute(window, config: config, plan: plan, eligible: eligible)
            await landed(outcome)
            return outcome
        }
        return outcome ?? .superseded
    }

    public func run(_ request: MoveRequest, config: Config) async -> PlacementOutcome {
        await run(request.window, config: config) { _ in .request(request) }
    }

    // MARK: Stages

    private func execute(
        _ window: WindowHandle,
        config: Config,
        plan: @Sendable (ResolvedWindow) -> PlanResult,
        eligible: @Sendable () async -> Bool
    ) async -> PlacementOutcome {
        // Read first: a reconfiguration that begins after this cancels the write.
        let epoch = await writer.epoch
        let resolved: ResolvedWindow
        switch await resolve(window) {
        case .failed(let kind): return .failed(kind)
        case .resolved(let value): resolved = value
        }
        let snapshot = resolved.snapshot
        let request: MoveRequest
        switch plan(resolved) {
        case .nothing: return .unchanged
        case .fail(let kind): return .failed(kind)
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
            return .unchanged
        }

        let job = WriteJob(
            window: window,
            appName: snapshot.appName,
            start: snapshot.frame,
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
        let result = await writer.write(job) {
            guard await eligible() else { return false }
            writing.withLock { $0 = true }
            if opensChain { await keeper.update { $0.openChain(window, before: snapshot.frame, on: current) } }
            return true
        }
        return await record(
            result, for: request, snapshot: snapshot, displays: resolved.displays, fallback: target,
            wrote: writing.withLock { $0 }
        )
    }

    /// Resolve: the window, its display, and the memory about it, reconciled with where the
    /// window is.
    private func resolve(_ window: WindowHandle) async -> Resolution {
        let snapshot: WindowSnapshot
        switch await platform.snapshot(of: window) {
        case .failure(let failure): return .failed(await failureKind(failure, window: window, appName: nil))
        case .success(let value): snapshot = value
        }
        if snapshot.isFullscreen { return .failed(.fullscreen) }
        if snapshot.isSheet || !snapshot.canMove { return .failed(.cannotMove) }
        let displays = await platform.displays()
        guard let current = DisplayLocator.display(containing: snapshot.frame, in: displays) else {
            return .failed(.cannotMove)
        }
        // A window that has left the frame Tafl put it in was moved by something Tafl did not see.
        let known = await memory.update { memory -> (placed: PlacedRecord?, atAchieved: Bool, restore: (ScreenRect, Display)?) in
            if memory.placed[window] != nil, !memory.isAtAchievedFrame(window, frame: snapshot.frame) {
                memory.recordExternalChange(window)
            }
            return (
                memory.placed[window],
                memory.isAtAchievedFrame(window, frame: snapshot.frame),
                memory.restoreTarget(window, current: current, displays: displays)
            )
        }
        return .resolved(ResolvedWindow(
            snapshot: snapshot,
            display: current,
            displays: displays,
            placed: known.placed,
            isAtAchieved: known.atAchieved,
            restoreTarget: known.restore
        ))
    }

    /// Record: keeps the memory in step with what Apply did, and maps the result to an outcome.
    private func record(
        _ result: WriteResult,
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
            await memory.update { memory in
                memory.recordPlaced(window, record)
                if completesRestore { memory.completeRestore(window) }
            }
            switch result {
            case .sizeRefused: return .failed(.sizeRefused(app: snapshot.appName))
            case .positionRefused: return .failed(.cannotMove)
            default: return .placed(achieved)
            }
        case .interrupted:
            await memory.update { $0.recordExternalChange(window) }
            return .failed(.movedDuringPlacement)
        case .cancelled(let verified):
            if let verified { await recordOwn(verified, window, display: display(of: verified)) }
            return .superseded
        case .failed(let failure, let verified):
            if let verified {
                await recordOwn(verified, window, display: display(of: verified))
            } else if wrote {
                // Nothing verified after a write: the window is no longer at the old record, but
                // nothing external happened, so the chain stays open.
                await memory.update { $0.placed[window] = nil }
            }
            return .failed(await failureKind(failure, window: window, appName: snapshot.appName))
        }
    }

    /// A frame verified before a request stopped is Tafl's own, though nothing repeats from it.
    private func recordOwn(_ frame: ScreenRect, _ window: WindowHandle, display: DisplayIdentity) async {
        let record = PlacedRecord(
            action: nil, layout: nil, placement: nil, cycleStep: 0, achieved: frame, display: display
        )
        await memory.update { $0.recordPlaced(window, record) }
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
        await memory.update { memory in
            if opensChain { memory.openChain(window, before: frame, on: resolved.display) }
            memory.recordPlaced(window, record)
            if completesRestore { memory.completeRestore(window) }
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
