import Testing
@testable import TaflCore

struct ActionResolverTests {
    private let a = displayA
    private let b = displayB
    private let portrait = namedDisplay("Tall", rect(0, 0, 1080, 1920))

    private func config(_ mode: RepeatMode = .displays, gap: Double = 0, step: Double = 30) -> Config {
        Config(
            shortcuts: [:], repeatMode: mode, gap: gap, step: step,
            menuBarIcon: true, launchAtLogin: true, layouts: []
        )
    }

    private func record(_ action: Action, step: Int = 0, placement: NamedPlacement? = nil, on display: Display) -> PlacedRecord {
        PlacedRecord(
            action: action, layout: nil, placement: placement, cycleStep: step,
            achieved: display.visibleFrame, display: display.identity
        )
    }

    private func context(
        frame: ScreenRect = rect(100, 100, 400, 300),
        minSize: ScreenSize? = nil,
        on display: Display? = nil,
        displays: [Display]? = nil,
        pointer: DisplayIdentity? = nil,
        placed: PlacedRecord? = nil,
        atAchieved: Bool = false,
        restore: (frame: ScreenRect, display: Display)? = nil,
        mode: RepeatMode = .displays,
        gap: Double = 0
    ) -> ActionContext {
        var snapshot = window(1, frame: frame)
        snapshot.minSize = minSize
        let current = display ?? a
        return ActionContext(
            window: snapshot, display: current, displays: displays ?? [a, b], pointerDisplay: pointer,
            placed: placed, isAtAchieved: atAchieved, restoreTarget: restore, config: config(mode, gap: gap)
        )
    }

    private func frame(of plan: ActionPlan) -> ScreenRect? {
        if case .move(.frame(let frame), _, _, _) = plan { return frame }
        return nil
    }

    private func cell(_ columns: Int, _ rows: Int, _ column: Int, _ row: Int, _ columnSpan: Int, _ rowSpan: Int) -> GridCell {
        GridCell(columns: columns, rows: rows, column: column, row: row, columnSpan: columnSpan, rowSpan: rowSpan)
    }

    @Test func firstPressPlaces() {
        #expect(ActionResolver.plan(.leftHalf, context())
            == .move(.named(.leftHalf), to: a, placement: .leftHalf, cycleStep: 0))
    }

    @Test func displaysRepeat() {
        let left = context(placed: record(.leftHalf, placement: .leftHalf, on: a), atAchieved: true)
        #expect(ActionResolver.plan(.leftHalf, left)
            == .move(.named(.rightHalf), to: b, placement: .rightHalf, cycleStep: 0))
        let right = context(on: b, placed: record(.rightHalf, placement: .rightHalf, on: b), atAchieved: true)
        #expect(ActionResolver.plan(.rightHalf, right)
            == .move(.named(.leftHalf), to: a, placement: .leftHalf, cycleStep: 0))
    }

    @Test func displaysRepeatLeavesOtherActionsAlone() {
        let ctx = context(placed: record(.topHalf, placement: .topHalf, on: a), atAchieved: true)
        #expect(ActionResolver.plan(.topHalf, ctx)
            == .move(.named(.topHalf), to: a, placement: .topHalf, cycleStep: 0))
    }

    @Test func movedWindowDoesNotRepeat() {
        let ctx = context(placed: record(.leftHalf, placement: .leftHalf, on: a), atAchieved: false)
        #expect(ActionResolver.plan(.leftHalf, ctx)
            == .move(.named(.leftHalf), to: a, placement: .leftHalf, cycleStep: 0))
    }

    @Test func differentActionDoesNotRepeat() {
        let ctx = context(placed: record(.rightHalf, placement: .rightHalf, on: a), atAchieved: true)
        #expect(ActionResolver.plan(.leftHalf, ctx)
            == .move(.named(.leftHalf), to: a, placement: .leftHalf, cycleStep: 0))
    }

    @Test func singleDisplayRepeatDoesNothing() {
        let ctx = context(displays: [a], placed: record(.leftHalf, placement: .leftHalf, on: a), atAchieved: true)
        #expect(ActionResolver.plan(.leftHalf, ctx) == .nothing)
    }

    @Test func sizesCycle() {
        func plan(after step: Int) -> ActionPlan {
            let ctx = context(placed: record(.leftHalf, step: step, placement: .leftHalf, on: a), atAchieved: true, mode: .sizes)
            return ActionResolver.plan(.leftHalf, ctx)
        }
        #expect(plan(after: 0) == .move(.cell(cell(3, 1, 0, 0, 2, 1)), to: a, placement: nil, cycleStep: 1))
        #expect(plan(after: 1) == .move(.cell(cell(3, 1, 0, 0, 1, 1)), to: a, placement: nil, cycleStep: 2))
        #expect(plan(after: 2) == .move(.named(.leftHalf), to: a, placement: .leftHalf, cycleStep: 0))
    }

    @Test func sizesCycleCellsPerHalf() {
        func plan(_ action: Action, step: Int, on display: Display = displayA) -> ActionPlan {
            let ctx = context(on: display, placed: record(action, step: step, on: display), atAchieved: true, mode: .sizes)
            return ActionResolver.plan(action, ctx)
        }
        #expect(plan(.rightHalf, step: 0) == .move(.cell(cell(3, 1, 1, 0, 2, 1)), to: a, placement: nil, cycleStep: 1))
        #expect(plan(.rightHalf, step: 1) == .move(.cell(cell(3, 1, 2, 0, 1, 1)), to: a, placement: nil, cycleStep: 2))
        #expect(plan(.topHalf, step: 1, on: portrait) == .move(.cell(cell(1, 3, 0, 0, 1, 1)), to: portrait, placement: nil, cycleStep: 2))
        #expect(plan(.bottomHalf, step: 0) == .move(.cell(cell(1, 3, 0, 1, 1, 2)), to: a, placement: nil, cycleStep: 1))
        #expect(plan(.bottomHalf, step: 1) == .move(.cell(cell(1, 3, 0, 2, 1, 1)), to: a, placement: nil, cycleStep: 2))
    }

    @Test func sizesCycleOnPortraitTopHalf() {
        let ctx = context(on: portrait, placed: record(.topHalf, step: 0, placement: .topHalf, on: portrait), atAchieved: true, mode: .sizes)
        #expect(ActionResolver.plan(.topHalf, ctx)
            == .move(.cell(cell(1, 3, 0, 0, 1, 2)), to: portrait, placement: nil, cycleStep: 1))
    }

    @Test func sizesModeLeavesQuartersAlone() {
        let ctx = context(placed: record(.topLeft, placement: .topLeft, on: a), atAchieved: true, mode: .sizes)
        #expect(ActionResolver.plan(.topLeft, ctx)
            == .move(.named(.topLeft), to: a, placement: .topLeft, cycleStep: 0))
    }

    @Test func noneRepeatDoesNothing() {
        let ctx = context(placed: record(.leftHalf, placement: .leftHalf, on: a), atAchieved: true, mode: .none)
        #expect(ActionResolver.plan(.leftHalf, ctx) == .nothing)
    }

    @Test func noneModeStillResizesRepeatedLarger() {
        let ctx = context(placed: record(.larger, on: a), atAchieved: true, mode: .none)
        #expect(frame(of: ActionResolver.plan(.larger, ctx)) == rect(70, 70, 460, 360))
    }

    @Test func maximizeHeightAndCenter() {
        #expect(ActionResolver.plan(.maximizeHeight, context())
            == .move(.maximizeHeight, to: a, placement: nil, cycleStep: 0))
        #expect(ActionResolver.plan(.center, context())
            == .move(.center, to: a, placement: nil, cycleStep: 0))
    }

    @Test func larger() {
        #expect(frame(of: ActionResolver.plan(.larger, context(frame: rect(100, 100, 400, 300)))) == rect(70, 70, 460, 360))
        #expect(frame(of: ActionResolver.plan(.larger, context(frame: rect(10, 30, 400, 300)))) == rect(0, 25, 440, 335))
    }

    @Test func largerStopsAtTheFarEdges() {
        #expect(frame(of: ActionResolver.plan(.larger, context(frame: rect(600, 450, 390, 340)))) == rect(570, 420, 430, 380))
    }

    @Test func largerNeverShrinksAWindowPastTheEdge() {
        #expect(frame(of: ActionResolver.plan(.larger, context(frame: rect(-20, 100, 400, 300)))) == rect(-20, 70, 430, 360))
    }

    @Test func smaller() {
        #expect(frame(of: ActionResolver.plan(.smaller, context(frame: rect(100, 100, 400, 300)))) == rect(130, 130, 340, 240))
        #expect(frame(of: ActionResolver.plan(.smaller, context(frame: rect(100, 100, 220, 170)))) == rect(110, 110, 200, 150))
    }

    @Test func smallerStopsAtTheWindowsMinimumSize() {
        let tight = context(frame: rect(100, 100, 320, 220), minSize: ScreenSize(width: 300, height: 200))
        #expect(frame(of: ActionResolver.plan(.smaller, tight)) == rect(110, 110, 300, 200))
        let loose = context(frame: rect(100, 100, 400, 300), minSize: ScreenSize(width: 100, height: 80))
        #expect(frame(of: ActionResolver.plan(.smaller, loose)) == rect(130, 130, 340, 240))
    }

    @Test func smallerNeverGrowsAWindow() {
        let ctx = context(frame: rect(100, 100, 180, 140))
        #expect(frame(of: ActionResolver.plan(.smaller, ctx)) == rect(100, 100, 180, 140))
    }

    @Test func restoreWithAndWithoutRecord() {
        #expect(ActionResolver.plan(.restore, context()) == .nothing)
        let ctx = context(restore: (frame: rect(5, 40, 600, 500), display: b))
        #expect(ActionResolver.plan(.restore, ctx)
            == .move(.frame(rect(5, 40, 600, 500)), to: b, placement: nil, cycleStep: 0))
    }

    @Test func displayMoveKeepsPlacement() {
        let ctx = context(frame: rect(0, 25, 500, 775), placed: record(.leftHalf, placement: .leftHalf, on: a), atAchieved: true)
        #expect(ActionResolver.plan(.displayRight, ctx)
            == .move(.named(.leftHalf), to: b, placement: .leftHalf, cycleStep: 0))
    }

    @Test func displayMoveRecognisesAMovedWindowsPlacement() {
        let ctx = context(frame: rect(0, 25, 500, 775), placed: record(.rightHalf, placement: .rightHalf, on: a), atAchieved: false)
        #expect(ActionResolver.plan(.displayRight, ctx)
            == .move(.named(.leftHalf), to: b, placement: .leftHalf, cycleStep: 0))
    }

    @Test func displayMoveKeepsRelativeFrame() throws {
        let plan = ActionResolver.plan(.displayRight, context(frame: rect(100, 100, 400, 300)))
        guard case .move(.relative(let relative), let target, nil, 0) = plan else {
            Issue.record("expected a relative move, got \(plan)")
            return
        }
        #expect(target == b)
        #expect(relative.absolute(in: b.visibleFrame) == rect(1200, 150, 800, 600))
    }

    @Test func noDisplayThatWay() {
        for action in [Action.displayLeft, .displayRight, .displayUp, .displayDown] {
            #expect(ActionResolver.plan(action, context(displays: [a])) == .fail(.noDisplayThatWay))
        }
    }

    @Test func displayLeftWrapsToTheOtherDisplay() {
        let ctx = context(frame: rect(0, 25, 500, 775))
        #expect(ActionResolver.plan(.displayLeft, ctx)
            == .move(.named(.leftHalf), to: b, placement: .leftHalf, cycleStep: 0))
    }

    @Test func pointerOnOtherDisplayMoves() {
        let ctx = context(frame: rect(0, 25, 500, 775), pointer: b.identity)
        #expect(ActionResolver.plan(.displayUnderPointer, ctx)
            == .move(.named(.leftHalf), to: b, placement: .leftHalf, cycleStep: 0))
    }

    @Test func pointerOnSameDisplayDoesNothing() {
        #expect(ActionResolver.plan(.displayUnderPointer, context(pointer: a.identity)) == .nothing)
    }

    @Test func pointerOnNoDisplayFails() {
        #expect(ActionResolver.plan(.displayUnderPointer, context(pointer: nil)) == .fail(.noDisplayThatWay))
        let stranger = DisplayIdentity(name: "Gone", vendor: 9, model: 9, serial: 9)
        #expect(ActionResolver.plan(.displayUnderPointer, context(pointer: stranger)) == .fail(.noDisplayThatWay))
    }

    @Test func displayMoveRecognisesPlacementWhenTheRecordHasNone() {
        let ctx = context(
            frame: rect(10, 35, 652, 755),
            placed: record(.leftHalf, step: 1, placement: nil, on: a),
            atAchieved: true, mode: .sizes, gap: 10
        )
        #expect(ActionResolver.plan(.displayRight, ctx)
            == .move(.named(.firstTwoThirds), to: b, placement: .firstTwoThirds, cycleStep: 0))
    }

    @Test func recordedPlacementBeatsTheRecogniserAtTheAchievedFrame() {
        let ctx = context(frame: rect(0, 25, 497, 770), placed: record(.leftHalf, placement: .leftHalf, on: a), atAchieved: true)
        #expect(ActionResolver.plan(.displayRight, ctx)
            == .move(.named(.leftHalf), to: b, placement: .leftHalf, cycleStep: 0))
    }

    @Test func leftHalfPressesWalkAcrossDisplaysLikeRectangle() {
        var placed: PlacedRecord?
        var current = a
        var steps: [(NamedPlacement, String)] = []
        for _ in 0..<5 {
            let ctx = context(on: current, placed: placed, atAchieved: placed != nil)
            guard case .move(.named(let half), let target, let kept, let cycleStep) = ActionResolver.plan(.leftHalf, ctx) else {
                Issue.record("expected a named move")
                return
            }
            steps.append((half, target.identity.name))
            placed = PlacedRecord(
                action: .leftHalf, layout: nil, placement: kept, cycleStep: cycleStep,
                achieved: target.visibleFrame, display: target.identity
            )
            current = target
        }
        #expect(steps.map(\.0) == [.leftHalf, .rightHalf, .leftHalf, .rightHalf, .leftHalf])
        #expect(steps.map(\.1) == ["Built-in", "Desk", "Desk", "Built-in", "Built-in"])
    }

    @Test func leftHalfOnTheOtherHalfsResultIsAFirstPress() {
        let ctx = context(on: b, placed: record(.leftHalf, placement: .rightHalf, on: b), atAchieved: true)
        #expect(ActionResolver.plan(.leftHalf, ctx)
            == .move(.named(.leftHalf), to: b, placement: .leftHalf, cycleStep: 0))
    }

    @Test func pointerWithASingleDisplayFails() {
        let ctx = context(displays: [a], pointer: a.identity)
        #expect(ActionResolver.plan(.displayUnderPointer, ctx) == .fail(.noDisplayThatWay))
    }

    @Test func requestSourcesCountForRestore() {
        #expect(RequestSource.action(.leftHalf).countsForRestore)
        #expect(RequestSource.layout("desk").countsForRestore)
        #expect(RequestSource.newWindow(layout: "desk").countsForRestore)
        #expect(!RequestSource.displayChange.countsForRestore)
        #expect(!RequestSource.action(.restore).countsForRestore)
    }
}
