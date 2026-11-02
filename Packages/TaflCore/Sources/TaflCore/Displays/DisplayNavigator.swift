import Foundation

public enum Direction: Sendable {
    case left, right, up, down
}

public enum DisplayNavigator {
    public static func target(from: DisplayIdentity, _ direction: Direction, in displays: [Display]) -> Display? {
        guard displays.count > 1, let origin = displays.first(where: { $0.identity == from }) else { return nil }
        let order = fallbackOrder(displays)
        let candidates = order.enumerated().filter { $0.element.identity != from && lies($0.element, in: direction, of: origin) }
        let nearest = candidates.min {
            let (a, b) = ($0.element.frame.distance(toCentreOf: origin.frame), $1.element.frame.distance(toCentreOf: origin.frame))
            return a != b ? a < b : $0.offset < $1.offset
        }
        if let nearest { return nearest.element }
        guard let index = order.firstIndex(where: { $0.identity == from }) else { return nil }
        let step = (direction == .left || direction == .up) ? -1 : 1
        return order[(index + step + order.count) % order.count]
    }

    /// Rows from top to bottom, as Rectangle's `yThenMinX`: a display joins a row when it
    /// overlaps vertically with a display already in it; each row runs left to right.
    public static func fallbackOrder(_ displays: [Display]) -> [Display] {
        var rows: [[Display]] = []
        for display in displays.sorted(by: { $0.frame.minY < $1.frame.minY }) {
            if let index = rows.firstIndex(where: { row in row.contains { overlapsVertically($0, display) } }) {
                rows[index].append(display)
            } else {
                rows.append([display])
            }
        }
        return rows.flatMap { row in
            row.sorted {
                ($0.frame.minX, $0.frame.minY, $0.identity.identifier)
                    < ($1.frame.minX, $1.frame.minY, $1.identity.identifier)
            }
        }
    }

    private static func overlapsVertically(_ a: Display, _ b: Display) -> Bool {
        a.frame.minY < b.frame.maxY && b.frame.minY < a.frame.maxY
    }

    private static func lies(_ candidate: Display, in direction: Direction, of origin: Display) -> Bool {
        switch direction {
        case .left: candidate.frame.midX < origin.frame.midX
        case .right: candidate.frame.midX > origin.frame.midX
        case .up: candidate.frame.midY < origin.frame.midY
        case .down: candidate.frame.midY > origin.frame.midY
        }
    }
}
