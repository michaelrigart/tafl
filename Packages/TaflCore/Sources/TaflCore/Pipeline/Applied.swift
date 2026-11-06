import Foundation

/// What the stages after Resolve's reading came to. The owner records it on the window's placement
/// in the step that ends the request.
enum Applied {
    /// Stopped before writing, by Resolve or by the plan: nothing to record.
    case stopped(PlacementOutcome)
    /// The window is already where the request puts it.
    case unchanged(MoveRequest, frame: ScreenRect, display: Display)
    /// Apply ran.
    case wrote(WriteResult, MoveRequest, displays: [Display], fallback: Display)

    /// Keeps the window's placement in step with what the request did. An interruption was recorded
    /// by the reading that showed it, and stands.
    func record(_ ending: RequestEnding, _ placement: inout WindowPlacement) {
        guard !ending.interrupted else { return }
        switch self {
        case .stopped:
            return
        case .unchanged(let request, let frame, let display):
            // A request whose target is where the window already is: the window counts as placed by
            // it, and a restore that is already done completes. A display change leaves it alone.
            guard request.source != .displayChange else { return }
            if request.source.countsForRestore { placement.openChain(before: frame, on: display) }
            placement.recordPlaced(Self.placedRecord(request, achieved: frame, display: display.identity))
            if request.source.completesRestore { placement.completeRestore() }
        case .wrote(let result, let request, let displays, let fallback):
            func display(of frame: ScreenRect) -> DisplayIdentity {
                (DisplayLocator.display(containing: frame, in: displays) ?? fallback).identity
            }
            switch result {
            case .placed(let achieved), .sizeRefused(let achieved), .positionRefused(let achieved):
                placement.recordPlaced(Self.placedRecord(request, achieved: achieved, display: display(of: achieved)))
                if request.source.completesRestore, result == .placed(achieved) { placement.completeRestore() }
            case .interrupted:
                return
            case .cancelled(let verified):
                if let verified { placement.recordPlaced(Self.ownRecord(verified, display: display(of: verified))) }
            case .failed(_, let verified):
                if let verified {
                    placement.recordPlaced(Self.ownRecord(verified, display: display(of: verified)))
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
