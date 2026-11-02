import Foundation

public struct PlacedRecord: Codable, Equatable, Sendable {
    public var action: Action?
    public var layout: String?
    public var placement: NamedPlacement?
    public var cycleStep: Int
    public var achieved: ScreenRect
    public var display: DisplayIdentity

    public init(
        action: Action?,
        layout: String?,
        placement: NamedPlacement?,
        cycleStep: Int,
        achieved: ScreenRect,
        display: DisplayIdentity
    ) {
        self.action = action
        self.layout = layout
        self.placement = placement
        self.cycleStep = cycleStep
        self.achieved = achieved
        self.display = display
    }
}

public struct RestoreRecord: Codable, Equatable, Sendable {
    public var frame: ScreenRect
    public var display: DisplayIdentity
    public var visibleFrame: ScreenRect
    public var chainOpen: Bool

    public init(frame: ScreenRect, display: DisplayIdentity, visibleFrame: ScreenRect, chainOpen: Bool) {
        self.frame = frame
        self.display = display
        self.visibleFrame = visibleFrame
        self.chainOpen = chainOpen
    }
}

public struct StoredFrame: Codable, Equatable, Sendable {
    public var display: DisplayIdentity
    public var relative: UnitRect

    public init(display: DisplayIdentity, relative: UnitRect) {
        self.display = display
        self.relative = relative
    }
}

public struct WindowMemory: Codable, Equatable, Sendable {
    public static let fileVersion = 1

    public var placed: [WindowHandle: PlacedRecord]
    public var restore: [WindowHandle: RestoreRecord]
    public var lastKnown: [DisplaySetup: [WindowHandle: StoredFrame]]
    public var activeLayout: String?
    /// The displays, with their geometry, when Tafl last ran or last settled a change.
    public var lastDisplays: [Display]

    public init(
        placed: [WindowHandle: PlacedRecord] = [:],
        restore: [WindowHandle: RestoreRecord] = [:],
        lastKnown: [DisplaySetup: [WindowHandle: StoredFrame]] = [:],
        activeLayout: String? = nil,
        lastDisplays: [Display] = []
    ) {
        self.placed = placed
        self.restore = restore
        self.lastKnown = lastKnown
        self.activeLayout = activeLayout
        self.lastDisplays = lastDisplays
    }

    public var lastSetup: DisplaySetup? {
        lastDisplays.isEmpty ? nil : DisplaySetup(lastDisplays)
    }

    public mutating func openChain(_ window: WindowHandle, before: ScreenRect, on display: Display) {
        if restore[window]?.chainOpen == true { return }
        restore[window] = RestoreRecord(
            frame: before,
            display: display.identity,
            visibleFrame: display.visibleFrame,
            chainOpen: true
        )
    }

    public mutating func recordPlaced(_ window: WindowHandle, _ record: PlacedRecord) {
        placed[window] = record
    }

    public mutating func recordExternalChange(_ window: WindowHandle) {
        placed[window] = nil
        restore[window]?.chainOpen = false
    }

    public func isAtAchievedFrame(_ window: WindowHandle, frame: ScreenRect) -> Bool {
        guard let record = placed[window] else { return false }
        return record.achieved.isClose(to: frame, within: 1)
    }

    public func restoreTarget(
        _ window: WindowHandle,
        current: Display,
        displays: [Display]
    ) -> (ScreenRect, Display)? {
        guard let record = restore[window] else { return nil }
        if let home = displays.first(where: { $0.identity == record.display }) {
            return (record.frame, home)
        }
        let origin = Display(identity: record.display, frame: record.visibleFrame, visibleFrame: record.visibleFrame)
        return (DisplayTransfer.relative(record.frame, from: origin, to: current), current)
    }

    public mutating func completeRestore(_ window: WindowHandle) {
        restore[window] = nil
    }

    public mutating func recordLastKnown(
        _ window: WindowHandle,
        frame: ScreenRect,
        display: Display,
        setup: DisplaySetup
    ) {
        lastKnown[setup, default: [:]][window] = StoredFrame(
            display: display.identity,
            relative: frame.relative(to: display.visibleFrame)
        )
    }

    public func lastKnown(_ window: WindowHandle, setup: DisplaySetup) -> StoredFrame? {
        lastKnown[setup]?[window]
    }

    public func absolute(_ stored: StoredFrame, in displays: [Display]) -> ScreenRect? {
        guard let display = displays.first(where: { $0.identity == stored.display }) else { return nil }
        return stored.relative.absolute(in: display.visibleFrame)
    }

    public mutating func forget(_ window: WindowHandle) {
        forget { $0 == window }
    }

    public mutating func forget(pid: Int32) {
        forget { $0.pid == pid }
    }

    private mutating func forget(where matches: (WindowHandle) -> Bool) {
        placed = placed.filter { !matches($0.key) }
        restore = restore.filter { !matches($0.key) }
        lastKnown = lastKnown
            .mapValues { $0.filter { !matches($0.key) } }
            .filter { !$0.value.isEmpty }
    }

    func droppingUnstableHandles() -> WindowMemory {
        var copy = self
        copy.forget { !$0.isStable }
        return copy
    }
}

// Dictionaries keyed by structs encode as arrays of entries, sorted, so the file is
// readable and stable.
extension WindowMemory {
    private enum CodingKeys: String, CodingKey {
        case version, placed, restore, lastKnown, activeLayout, lastDisplays
    }

    private struct PlacedEntry: Codable {
        var window: WindowHandle
        var record: PlacedRecord
    }

    private struct RestoreEntry: Codable {
        var window: WindowHandle
        var record: RestoreRecord
    }

    private struct FrameEntry: Codable {
        var window: WindowHandle
        var frame: StoredFrame
    }

    private struct SetupEntry: Codable {
        var displays: [DisplayIdentity]
        var frames: [FrameEntry]
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        placed = Dictionary(
            try container.decode([PlacedEntry].self, forKey: .placed).map { ($0.window, $0.record) },
            uniquingKeysWith: { _, last in last }
        )
        restore = Dictionary(
            try container.decode([RestoreEntry].self, forKey: .restore).map { ($0.window, $0.record) },
            uniquingKeysWith: { _, last in last }
        )
        var known: [DisplaySetup: [WindowHandle: StoredFrame]] = [:]
        for entry in try container.decode([SetupEntry].self, forKey: .lastKnown) {
            var setup = DisplaySetup([])
            setup.identities = Set(entry.displays)
            for frame in entry.frames { known[setup, default: [:]][frame.window] = frame.frame }
        }
        lastKnown = known
        activeLayout = try container.decodeIfPresent(String.self, forKey: .activeLayout)
        lastDisplays = try container.decode([Display].self, forKey: .lastDisplays)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.fileVersion, forKey: .version)
        try container.encode(
            placed.map { PlacedEntry(window: $0.key, record: $0.value) }.sorted { $0.window.precedes($1.window) },
            forKey: .placed
        )
        try container.encode(
            restore.map { RestoreEntry(window: $0.key, record: $0.value) }.sorted { $0.window.precedes($1.window) },
            forKey: .restore
        )
        let setups = lastKnown.map { setup, frames in
            SetupEntry(
                displays: setup.identities.sorted { $0.order < $1.order },
                frames: frames.map { FrameEntry(window: $0.key, frame: $0.value) }
                    .sorted { $0.window.precedes($1.window) }
            )
        }
        .sorted { $0.displays.map(\.order).joined(separator: ",") < $1.displays.map(\.order).joined(separator: ",") }
        try container.encode(setups, forKey: .lastKnown)
        try container.encodeIfPresent(activeLayout, forKey: .activeLayout)
        try container.encode(lastDisplays, forKey: .lastDisplays)
    }
}

private extension WindowHandle {
    func precedes(_ other: WindowHandle) -> Bool {
        (pid, windowID) < (other.pid, other.windowID)
    }
}

private extension DisplayIdentity {
    var order: String { "\(identifier)|\(name)" }
}
