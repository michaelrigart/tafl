import Foundation

public struct WindowAtChange: Sendable {
    public var snapshot: WindowSnapshot
    /// Last known on the old setup, frozen when the change began.
    public var previous: StoredFrame?
    /// Last known on the new setup.
    public var remembered: StoredFrame?
    public var isObserved: Bool

    public init(snapshot: WindowSnapshot, previous: StoredFrame?, remembered: StoredFrame?, isObserved: Bool) {
        self.snapshot = snapshot
        self.previous = previous
        self.remembered = remembered
        self.isObserved = isObserved
    }
}

public enum DisplayChangeRules {
    public static func plan(
        oldDisplays: [Display],
        newDisplays: [Display],
        windows: [WindowAtChange],
        claiming: LayoutDefinition?,
        gap: Double
    ) -> [MoveRequest] {
        windows.compactMap { entry in
            let snapshot = entry.snapshot
            guard entry.isObserved, !snapshot.isFullscreen, !snapshot.isMinimized,
                  !snapshot.isAppHidden, !snapshot.isSheet
            else { return nil }

            if let claiming, LayoutPlanner.entryIndex(for: snapshot, in: claiming) != nil {
                return LayoutPlanner.requests(
                    claiming, windows: [snapshot], displays: newDisplays, source: .displayChange
                ).first
            }
            if let remembered = entry.remembered,
               let home = newDisplays.first(where: { $0.identity == remembered.display }) {
                return request(snapshot, .frame(remembered.relative.absolute(in: home.visibleFrame)), on: home)
            }
            if let previous = entry.previous,
               !newDisplays.contains(where: { $0.identity == previous.display }),
               let current = DisplayLocator.display(containing: snapshot.frame, in: newDisplays) {
                if let old = oldDisplays.first(where: { $0.identity == previous.display }),
                   let placement = PlacementRecognizer.recognize(
                       previous.relative.absolute(in: old.visibleFrame), on: old, gap: gap
                   ) {
                    return request(snapshot, .named(placement), on: current, placement: placement)
                }
                return request(snapshot, .relative(previous.relative), on: current)
            }
            return nil
        }
    }

    private static func request(
        _ snapshot: WindowSnapshot,
        _ spec: PlacementSpec,
        on display: Display,
        placement: NamedPlacement? = nil
    ) -> MoveRequest {
        MoveRequest(
            window: snapshot.handle,
            spec: spec,
            display: display.identity,
            placement: placement,
            cycleStep: 0,
            source: .displayChange
        )
    }
}
