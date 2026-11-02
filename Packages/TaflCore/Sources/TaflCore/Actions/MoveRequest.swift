import Foundation

public enum RequestSource: Equatable, Sendable {
    case action(Action)
    case layout(String)
    case displayChange
    case newWindow(layout: String)

    /// Whether a placement from this source starts or extends a restore chain.
    public var countsForRestore: Bool {
        switch self {
        case .action(let action): action != .restore
        case .layout, .newWindow: true
        case .displayChange: false
        }
    }
}

public struct MoveRequest: Equatable, Sendable {
    public var window: WindowHandle
    public var spec: PlacementSpec
    public var display: DisplayIdentity
    public var placement: NamedPlacement?
    public var cycleStep: Int
    public var source: RequestSource

    public init(
        window: WindowHandle,
        spec: PlacementSpec,
        display: DisplayIdentity,
        placement: NamedPlacement?,
        cycleStep: Int,
        source: RequestSource
    ) {
        self.window = window
        self.spec = spec
        self.display = display
        self.placement = placement
        self.cycleStep = cycleStep
        self.source = source
    }
}
