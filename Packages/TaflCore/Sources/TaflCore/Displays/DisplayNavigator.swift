import Foundation

public enum Direction: Sendable {
    case left, right, up, down
}

public enum DisplayNavigator {
    public static func target(from: DisplayIdentity, _ direction: Direction, in displays: [Display]) -> Display? {
        guard displays.count > 1, let origin = displays.first(where: { $0.identity == from }) else { return nil }
        let candidates = displays.filter { $0.identity != from && lies($0, in: direction, of: origin) }
        if let nearest = candidates.min(by: { distance($0, origin) < distance($1, origin) }) {
            return nearest
        }
        let order = fallbackOrder(displays)
        guard let index = order.firstIndex(where: { $0.identity == from }) else { return nil }
        let step = (direction == .left || direction == .up) ? -1 : 1
        return order[(index + step + order.count) % order.count]
    }

    public static func fallbackOrder(_ displays: [Display]) -> [Display] {
        displays.sorted {
            ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX)
        }
    }

    private static func lies(_ candidate: Display, in direction: Direction, of origin: Display) -> Bool {
        switch direction {
        case .left: candidate.frame.midX < origin.frame.midX
        case .right: candidate.frame.midX > origin.frame.midX
        case .up: candidate.frame.midY < origin.frame.midY
        case .down: candidate.frame.midY > origin.frame.midY
        }
    }

    private static func distance(_ a: Display, _ b: Display) -> Double {
        let dx = a.frame.midX - b.frame.midX
        let dy = a.frame.midY - b.frame.midY
        return (dx * dx + dy * dy).squareRoot()
    }
}
