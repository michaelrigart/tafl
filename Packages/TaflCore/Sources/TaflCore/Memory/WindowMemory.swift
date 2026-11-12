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
    /// The display's full frame, which the Dock and the menu bar don't change; nil in a file from
    /// before Tafl kept it, which a restore then judges by the visible frame.
    public var displayFrame: ScreenRect?
    public var chainOpen: Bool

    public init(
        frame: ScreenRect,
        display: DisplayIdentity,
        visibleFrame: ScreenRect,
        displayFrame: ScreenRect? = nil,
        chainOpen: Bool
    ) {
        self.frame = frame
        self.display = display
        self.visibleFrame = visibleFrame
        self.displayFrame = displayFrame
        self.chainOpen = chainOpen
    }
}

/// Where Tafl placed one window, and its restore chain: what a reading of that window may change.
public struct WindowPlacement: Equatable, Sendable {
    public var placed: PlacedRecord?
    public var restore: RestoreRecord?

    public init(placed: PlacedRecord? = nil, restore: RestoreRecord? = nil) {
        self.placed = placed
        self.restore = restore
    }

    public mutating func openChain(before: ScreenRect, on display: Display) {
        if restore?.chainOpen == true { return }
        restore = RestoreRecord(
            frame: before,
            display: display.identity,
            visibleFrame: display.visibleFrame,
            displayFrame: display.frame,
            chainOpen: true
        )
    }

    public mutating func recordPlaced(_ record: PlacedRecord) {
        placed = record
    }

    public mutating func recordExternalChange() {
        placed = nil
        restore?.chainOpen = false
    }

    public func isAtAchievedFrame(_ frame: ScreenRect) -> Bool {
        guard let placed else { return false }
        return placed.achieved.isClose(to: frame, within: 1)
    }

    public mutating func completeRestore() {
        restore = nil
    }

    /// Where Restore puts the window: the chain's start, on its display, exact while that display is
    /// unchanged, translated when it moved and mapped onto it when its size changed; mapped onto
    /// `current` when the display is no longer connected. A target mostly off every display is kept
    /// on screen.
    public func restoreTarget(current: Display, displays: [Display]) -> (ScreenRect, Display)? {
        guard let record = restore else { return nil }
        let home = displays.first(where: { $0.identity == record.display })
        let target = home ?? current
        let frame: ScreenRect
        if home != nil {
            frame = DisplayTransfer.carried(
                record.frame,
                recordedDisplay: record.displayFrame,
                recordedVisible: record.visibleFrame,
                to: target
            )
        } else {
            frame = DisplayTransfer.mapped(record.frame, from: record.visibleFrame, to: target.visibleFrame)
        }
        return (DisplayTransfer.keptOnScreen(frame, on: target, among: displays), target)
    }
}

/// A frame as it was recorded, with the frame and visible frame of its display then.
public struct RecordedFrame: Codable, Equatable, Sendable {
    public var frame: ScreenRect
    public var displayFrame: ScreenRect
    public var visibleFrame: ScreenRect

    public init(frame: ScreenRect, displayFrame: ScreenRect, visibleFrame: ScreenRect) {
        self.frame = frame
        self.displayFrame = displayFrame
        self.visibleFrame = visibleFrame
    }
}

public struct StoredFrame: Codable, Equatable, Sendable {
    public var display: DisplayIdentity
    public var relative: UnitRect
    /// The frame as it was; nil in a file from before Tafl kept it, which then goes by `relative`.
    public var recorded: RecordedFrame?

    public init(display: DisplayIdentity, relative: UnitRect, recorded: RecordedFrame? = nil) {
        self.display = display
        self.relative = relative
        self.recorded = recorded
    }

    /// Where the frame goes on `home` as it is now, by the rule `DisplayTransfer.carried` states.
    public func absolute(on home: Display) -> ScreenRect {
        guard let recorded else { return relative.absolute(in: home.visibleFrame) }
        return DisplayTransfer.carried(
            recorded.frame,
            recordedDisplay: recorded.displayFrame,
            recordedVisible: recorded.visibleFrame,
            to: home
        )
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
    /// When the memory was last saved; nil in a file from before Tafl kept it.
    public var savedAt: Date?

    public init(
        placed: [WindowHandle: PlacedRecord] = [:],
        restore: [WindowHandle: RestoreRecord] = [:],
        lastKnown: [DisplaySetup: [WindowHandle: StoredFrame]] = [:],
        activeLayout: String? = nil,
        lastDisplays: [Display] = [],
        savedAt: Date? = nil
    ) {
        self.placed = placed
        self.restore = restore
        self.lastKnown = lastKnown
        self.activeLayout = activeLayout
        self.lastDisplays = lastDisplays
        self.savedAt = savedAt
    }

    public var lastSetup: DisplaySetup? {
        lastDisplays.isEmpty ? nil : DisplaySetup(lastDisplays)
    }

    public func placement(of window: WindowHandle) -> WindowPlacement {
        WindowPlacement(placed: placed[window], restore: restore[window])
    }

    public mutating func setPlacement(_ placement: WindowPlacement, of window: WindowHandle) {
        placed[window] = placement.placed
        restore[window] = placement.restore
    }

    private mutating func changePlacement(of window: WindowHandle, _ change: (inout WindowPlacement) -> Void) {
        var placement = placement(of: window)
        change(&placement)
        setPlacement(placement, of: window)
    }

    public mutating func openChain(_ window: WindowHandle, before: ScreenRect, on display: Display) {
        changePlacement(of: window) { $0.openChain(before: before, on: display) }
    }

    public mutating func recordPlaced(_ window: WindowHandle, _ record: PlacedRecord) {
        changePlacement(of: window) { $0.recordPlaced(record) }
    }

    public mutating func recordExternalChange(_ window: WindowHandle) {
        changePlacement(of: window) { $0.recordExternalChange() }
    }

    public func isAtAchievedFrame(_ window: WindowHandle, frame: ScreenRect) -> Bool {
        placement(of: window).isAtAchievedFrame(frame)
    }

    public func restoreTarget(
        _ window: WindowHandle,
        current: Display,
        displays: [Display]
    ) -> (ScreenRect, Display)? {
        placement(of: window).restoreTarget(current: current, displays: displays)
    }

    public mutating func completeRestore(_ window: WindowHandle) {
        changePlacement(of: window) { $0.completeRestore() }
    }

    public mutating func recordLastKnown(
        _ window: WindowHandle,
        frame: ScreenRect,
        display: Display,
        setup: DisplaySetup
    ) {
        lastKnown[setup, default: [:]][window] = StoredFrame(
            display: display.identity,
            relative: frame.relative(to: display.visibleFrame),
            recorded: RecordedFrame(frame: frame, displayFrame: display.frame, visibleFrame: display.visibleFrame)
        )
    }

    public func lastKnown(_ window: WindowHandle, setup: DisplaySetup) -> StoredFrame? {
        lastKnown[setup]?[window]
    }

    public func absolute(_ stored: StoredFrame, in displays: [Display]) -> ScreenRect? {
        guard let display = displays.first(where: { $0.identity == stored.display }) else { return nil }
        return stored.absolute(on: display)
    }

    public mutating func forget(_ window: WindowHandle) {
        forget { $0 == window }
    }

    public mutating func forget(pid: Int32) {
        forget { $0.pid == pid }
    }

    public mutating func forget(pids: Set<Int32>) {
        forget { pids.contains($0.pid) }
    }

    /// The processes the window entries belong to.
    public var windowPids: Set<Int32> {
        Set(placed.keys.map(\.pid))
            .union(restore.keys.map(\.pid))
            .union(lastKnown.values.flatMap { $0.keys.map(\.pid) })
    }

    /// The processes whose entries name windows that are gone: a process without a launch date
    /// is not running, and one launched after the save has the id of one that quit. Without a
    /// save date no process is known to be the one the memory names.
    public func goneProcesses(launched: [Int32: Date]) -> Set<Int32> {
        guard let savedAt else { return windowPids }
        return windowPids.filter { pid in launched[pid].map { $0 > savedAt } ?? true }
    }

    /// Whether any entry belongs to a window that `matches`.
    func holdsWindow(where matches: (WindowHandle) -> Bool) -> Bool {
        placed.keys.contains(where: matches) || restore.keys.contains(where: matches)
            || lastKnown.values.contains { $0.keys.contains(where: matches) }
    }

    mutating func forget(where matches: (WindowHandle) -> Bool) {
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
        case version, placed, restore, lastKnown, activeLayout, lastDisplays, savedAt
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
        savedAt = try container.decodeIfPresent(Date.self, forKey: .savedAt)
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
        try container.encodeIfPresent(savedAt, forKey: .savedAt)
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
