import Foundation

public enum FailureKind: Equatable, Sendable {
    case noWindow
    case notResponding(app: String)
    case sizeRefused(app: String)
    case cannotMove
    case fullscreen
    case movedDuringPlacement
    case noDisplayThatWay
    case permissionMissing

    public var message: String {
        switch self {
        case .noWindow: "No window to move"
        case .notResponding(let app): "\(app) didn't respond"
        case .sizeRefused(let app): "\(app) kept its own size"
        case .cannotMove: "This window can't be moved"
        case .fullscreen: "Full-screen windows stay where they are"
        case .movedDuringPlacement: "The window was moved during placement"
        case .noDisplayThatWay: "No display that way"
        case .permissionMissing: "Tafl needs Accessibility permission"
        }
    }

    /// Every category `category` can return. Keep it in step with the cases above.
    public static let categories: Set<String> = Set([
        FailureKind.noWindow, .notResponding(app: ""), .sizeRefused(app: ""), .cannotMove, .fullscreen,
        .movedDuringPlacement, .noDisplayThatWay, .permissionMissing,
    ].map(\.category))

    public var category: String {
        switch self {
        case .noWindow: "no-window"
        case .notResponding: "not-responding"
        case .sizeRefused: "size-refused"
        case .cannotMove: "cannot-move"
        case .fullscreen: "fullscreen"
        case .movedDuringPlacement: "moved-during-placement"
        case .noDisplayThatWay: "no-display"
        case .permissionMissing: "permission-missing"
        }
    }
}
