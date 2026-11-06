import Foundation

/// Windows that were destroyed, and processes that quit: their memory is never written again.
struct GoneWindows: Sendable {
    private var windows: Set<WindowHandle> = []
    private var processes: Set<Int32> = []

    func contains(_ window: WindowHandle) -> Bool {
        windows.contains(window) || processes.contains(window.pid)
    }

    mutating func destroyed(_ window: WindowHandle) {
        windows.insert(window)
    }

    /// The process covers its windows from now on.
    mutating func quit(_ pid: Int32) {
        processes.insert(pid)
        windows = windows.filter { $0.pid != pid }
    }

    /// A new process has the id of one that quit.
    mutating func started(_ pid: Int32) {
        processes.remove(pid)
    }
}

/// What the memory holds that belongs to no window, so it changes without a reading.
public struct GeneralMemory: Sendable {
    public var activeLayout: String?
    /// The displays, with their geometry, when Tafl last ran or last settled a change.
    public var lastDisplays: [Display]
}

/// Owns the window memory and its store. It writes only after a load that left the file
/// replaceable, so a file written by another version, or one that can't be read, is never
/// overwritten. It also keeps which windows are gone, so no path writes their memory again. A
/// window's memory changes only from a reading of it that no newer one has overtaken: its
/// placement against the window's newest reading, which the writer shares, and its last-known
/// frames against the newest recorded for them.
public actor MemoryKeeper {
    private var memory: WindowMemory
    private let store: MemoryStore?
    private var mayWrite = false
    private var gone = GoneWindows()
    private let readings: WindowReadings
    private var lastKnownReadings = ReadingGate<WindowHandle>()

    public init(memory: WindowMemory = WindowMemory(), store: MemoryStore? = nil) {
        self.init(memory: memory, store: store, readings: WindowReadings())
    }

    init(memory: WindowMemory = WindowMemory(), store: MemoryStore? = nil, readings: WindowReadings) {
        self.memory = memory
        self.store = store
        self.readings = readings
    }

    /// Loads from the store. A loaded memory replaces the current one; every other result leaves
    /// it empty.
    public func load() -> MemoryLoad {
        guard let store else {
            mayWrite = true
            return .fresh
        }
        let result = store.load()
        switch result {
        case .loaded(let loaded):
            memory = loaded
            mayWrite = true
        case .fresh, .recoveredFromCorrupt:
            memory = WindowMemory()
            mayWrite = true
        case .refused, .unavailable:
            memory = WindowMemory()
            mayWrite = false
        }
        return result
    }

    public func read() -> WindowMemory {
        memory
    }

    /// Changes where Tafl placed a window, and its restore chain, from a reading of it taken at
    /// `readAt`: only when no newer reading of the window has been accepted, and only for a window
    /// that is not gone. The change reaches only that window's entries. Returns its result, or nil
    /// when the reading was refused; the newer state stands.
    @discardableResult
    public func recordPlacement<T>(
        _ window: WindowHandle,
        readAt: ContinuousClock.Instant,
        _ change: (inout WindowPlacement) -> T
    ) -> T? {
        guard !gone.contains(window), readings.accepts(window, readAt: readAt) else { return nil }
        var placement = memory.placement(of: window)
        let result = change(&placement)
        memory.setPlacement(placement, of: window)
        return result
    }

    /// Records a window's last-known frame for a setup from a reading of it taken at `readAt`,
    /// when no newer reading of the window has been recorded, `applies` holds, and the window is
    /// not gone. Returns whether the frame was recorded.
    @discardableResult
    public func recordLastKnown(
        _ window: WindowHandle,
        frame: ScreenRect,
        display: Display,
        setup: DisplaySetup,
        readAt: ContinuousClock.Instant,
        when applies: @Sendable () -> Bool = { true }
    ) -> Bool {
        guard !gone.contains(window), lastKnownReadings.admit(window, readAt: readAt), applies() else { return false }
        memory.recordLastKnown(window, frame: frame, display: display, setup: setup)
        return true
    }

    /// Changes what belongs to no window: the active layout and the displays.
    public func update<T>(_ change: (inout GeneralMemory) -> T) -> T {
        var general = GeneralMemory(activeLayout: memory.activeLayout, lastDisplays: memory.lastDisplays)
        let result = change(&general)
        memory.activeLayout = general.activeLayout
        memory.lastDisplays = general.lastDisplays
        return result
    }

    /// Drops what a loaded memory holds for these processes' windows. The processes are not marked
    /// gone: a process running now may have one of their ids.
    public func forgetEntries(of pids: Set<Int32>) {
        memory.forget(pids: pids)
    }

    /// The window was destroyed: its memory goes, for good.
    public func forget(_ window: WindowHandle) {
        gone.destroyed(window)
        memory.forget(window)
        lastKnownReadings.forget { $0 == window }
    }

    /// The app quit: the memory of its windows goes, for good.
    public func forget(pid: Int32) {
        gone.quit(pid)
        memory.forget(pid: pid)
        lastKnownReadings.forget { $0.pid == pid }
    }

    public func knows(_ window: WindowHandle) -> Bool {
        memory.holdsWindow { $0 == window }
    }

    /// A process started with this id, so a quit process that had it stands in its way no longer.
    public func processStarted(pid: Int32) {
        gone.started(pid)
    }

    /// Saves nothing when the last load must not be written over, or there is no store. The
    /// error is the store's: a `MemoryStoreError`, or the file system's. A save records when it
    /// was made.
    public func save() -> Result<Void, any Error> {
        guard let store, mayWrite else { return .success(()) }
        memory.savedAt = Date()
        return Result { try store.save(memory) }
    }
}
