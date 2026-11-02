import Foundation

public struct ActionContext: Sendable {
    public var window: WindowSnapshot
    /// The display the window is on now.
    public var display: Display
    public var displays: [Display]
    public var pointerDisplay: DisplayIdentity?
    public var placed: PlacedRecord?
    /// Whether the window is still where `placed` left it.
    public var isAtAchieved: Bool
    public var restoreTarget: (frame: ScreenRect, display: Display)?
    public var config: Config

    public init(
        window: WindowSnapshot,
        display: Display,
        displays: [Display],
        pointerDisplay: DisplayIdentity?,
        placed: PlacedRecord?,
        isAtAchieved: Bool,
        restoreTarget: (frame: ScreenRect, display: Display)?,
        config: Config
    ) {
        self.window = window
        self.display = display
        self.displays = displays
        self.pointerDisplay = pointerDisplay
        self.placed = placed
        self.isAtAchieved = isAtAchieved
        self.restoreTarget = restoreTarget
        self.config = config
    }
}

public enum ActionPlan: Equatable, Sendable {
    case move(PlacementSpec, to: Display, placement: NamedPlacement?, cycleStep: Int)
    case nothing
    case fail(FailureKind)
}

public enum ActionResolver {
    private static let defaultMinSize = ScreenSize(width: 200, height: 150)

    public static func plan(_ action: Action, _ context: ActionContext) -> ActionPlan {
        if let placement = gridPlacement(for: action) {
            return planGrid(action, placement, context)
        }
        switch action {
        case .maximizeHeight:
            return .move(.maximizeHeight, to: context.display, placement: nil, cycleStep: 0)
        case .center:
            return .move(.center, to: context.display, placement: nil, cycleStep: 0)
        case .larger:
            return .move(.frame(larger(context)), to: context.display, placement: nil, cycleStep: 0)
        case .smaller:
            return .move(.frame(smaller(context)), to: context.display, placement: nil, cycleStep: 0)
        case .restore:
            guard let target = context.restoreTarget else { return .nothing }
            return .move(.frame(target.frame), to: target.display, placement: nil, cycleStep: 0)
        case .displayLeft: return moveToDisplay(.left, context)
        case .displayRight: return moveToDisplay(.right, context)
        case .displayUp: return moveToDisplay(.up, context)
        case .displayDown: return moveToDisplay(.down, context)
        case .displayUnderPointer: return moveToPointerDisplay(context)
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf,
             .topLeft, .topRight, .bottomLeft, .bottomRight,
             .firstThird, .centerThird, .lastThird,
             .firstTwoThirds, .centerTwoThirds, .lastTwoThirds, .maximize:
            return .nothing
        }
    }

    private static func gridPlacement(for action: Action) -> NamedPlacement? {
        switch action {
        case .leftHalf: .leftHalf
        case .rightHalf: .rightHalf
        case .topHalf: .topHalf
        case .bottomHalf: .bottomHalf
        case .topLeft: .topLeft
        case .topRight: .topRight
        case .bottomLeft: .bottomLeft
        case .bottomRight: .bottomRight
        case .firstThird: .firstThird
        case .centerThird: .centerThird
        case .lastThird: .lastThird
        case .firstTwoThirds: .firstTwoThirds
        case .centerTwoThirds: .centerTwoThirds
        case .lastTwoThirds: .lastTwoThirds
        case .maximize: .maximize
        case .maximizeHeight, .center, .restore, .larger, .smaller,
             .displayLeft, .displayRight, .displayUp, .displayDown, .displayUnderPointer:
            nil
        }
    }

    // MARK: Grid actions and repeats

    private static func planGrid(_ action: Action, _ placement: NamedPlacement, _ context: ActionContext) -> ActionPlan {
        let first = ActionPlan.move(.named(placement), to: context.display, placement: placement, cycleStep: 0)
        guard let placed = context.placed, placed.action == action, context.isAtAchieved else { return first }
        switch context.config.repeatMode {
        case .none:
            return .nothing
        case .displays:
            guard placed.placement == placement else { return first }
            return repeatOnOtherDisplay(placement, context) ?? first
        case .sizes:
            return repeatSize(placement, placed, context) ?? first
        }
    }

    private static func repeatOnOtherDisplay(_ placement: NamedPlacement, _ context: ActionContext) -> ActionPlan? {
        let (direction, mirrored): (Direction, NamedPlacement)
        switch placement {
        case .leftHalf: (direction, mirrored) = (.left, .rightHalf)
        case .rightHalf: (direction, mirrored) = (.right, .leftHalf)
        default: return nil
        }
        guard let target = DisplayNavigator.target(from: context.display.identity, direction, in: context.displays) else {
            return .nothing
        }
        return .move(.named(mirrored), to: target, placement: mirrored, cycleStep: 0)
    }

    private static func repeatSize(_ placement: NamedPlacement, _ placed: PlacedRecord, _ context: ActionContext) -> ActionPlan? {
        let cells: (twoThirds: GridCell, third: GridCell)
        switch placement {
        case .leftHalf:
            cells = (GridCell(columns: 3, rows: 1, column: 0, row: 0, columnSpan: 2, rowSpan: 1),
                     GridCell(columns: 3, rows: 1, column: 0, row: 0, columnSpan: 1, rowSpan: 1))
        case .rightHalf:
            cells = (GridCell(columns: 3, rows: 1, column: 1, row: 0, columnSpan: 2, rowSpan: 1),
                     GridCell(columns: 3, rows: 1, column: 2, row: 0, columnSpan: 1, rowSpan: 1))
        case .topHalf:
            cells = (GridCell(columns: 1, rows: 3, column: 0, row: 0, columnSpan: 1, rowSpan: 2),
                     GridCell(columns: 1, rows: 3, column: 0, row: 0, columnSpan: 1, rowSpan: 1))
        case .bottomHalf:
            cells = (GridCell(columns: 1, rows: 3, column: 0, row: 1, columnSpan: 1, rowSpan: 2),
                     GridCell(columns: 1, rows: 3, column: 0, row: 2, columnSpan: 1, rowSpan: 1))
        default:
            return nil
        }
        let step = (placed.cycleStep + 1) % 3
        switch step {
        case 1: return .move(.cell(cells.twoThirds), to: context.display, placement: nil, cycleStep: 1)
        case 2: return .move(.cell(cells.third), to: context.display, placement: nil, cycleStep: 2)
        default: return .move(.named(placement), to: context.display, placement: placement, cycleStep: 0)
        }
    }

    // MARK: Larger and smaller

    private static func larger(_ context: ActionContext) -> ScreenRect {
        let frame = context.window.frame
        let visible = context.display.visibleFrame
        let step = context.config.step
        let left = min(frame.minX, max(frame.minX - step, visible.minX))
        let top = min(frame.minY, max(frame.minY - step, visible.minY))
        let right = max(frame.maxX, min(frame.maxX + step, visible.maxX))
        let bottom = max(frame.maxY, min(frame.maxY + step, visible.maxY))
        return ScreenRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    private static func smaller(_ context: ActionContext) -> ScreenRect {
        let frame = context.window.frame
        let floor = context.window.minSize ?? defaultMinSize
        let step = context.config.step
        let dx = max(0, min(step, (frame.width - floor.width) / 2))
        let dy = max(0, min(step, (frame.height - floor.height) / 2))
        return ScreenRect(x: frame.x + dx, y: frame.y + dy, width: frame.width - 2 * dx, height: frame.height - 2 * dy)
    }

    // MARK: Display moves

    private static func moveToDisplay(_ direction: Direction, _ context: ActionContext) -> ActionPlan {
        guard let target = DisplayNavigator.target(from: context.display.identity, direction, in: context.displays) else {
            return .fail(.noDisplayThatWay)
        }
        return keepingPlacement(on: target, context)
    }

    private static func moveToPointerDisplay(_ context: ActionContext) -> ActionPlan {
        guard context.displays.count > 1,
              let pointer = context.pointerDisplay,
              let target = context.displays.first(where: { $0.identity == pointer })
        else { return .fail(.noDisplayThatWay) }
        guard target.identity != context.display.identity else { return .nothing }
        return keepingPlacement(on: target, context)
    }

    private static func keepingPlacement(on target: Display, _ context: ActionContext) -> ActionPlan {
        let kept = (context.isAtAchieved ? context.placed?.placement : nil)
            ?? PlacementRecognizer.recognize(context.window.frame, on: context.display, gap: context.config.gap)
        if let kept {
            return .move(.named(kept), to: target, placement: kept, cycleStep: 0)
        }
        let relative = context.window.frame.relative(to: context.display.visibleFrame)
        return .move(.relative(relative), to: target, placement: nil, cycleStep: 0)
    }
}
