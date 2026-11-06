import Foundation

/// Windows that were destroyed, and processes that quit: their memory is never written again.
struct GoneWindows: Sendable {
    private var windows: Set<WindowHandle> = []
    private var processes: Set<Int32> = []

    var isEmpty: Bool { windows.isEmpty && processes.isEmpty }

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

/// The parts of a window's memory. Each accepts a reading only when it is at least as new as the
/// newest that part has accepted for the window.
public enum MemoryPart: Sendable {
    /// The window's last-known frames.
    case lastKnown
    /// Where Tafl placed the window, and its restore chain.
    case placement
}

/// What the memory holds that belongs to no window, so it changes without a reading.
public struct GeneralMemory: Sendable {
    public var activeLayout: String?
    /// The displays, with their geometry, when Tafl last ran or last settled a change.
    public var lastDisplays: [Display]
}

/// Owns the window memory and its store. It writes only after a load that left the file
/// replaceable, so a file written by another version, or one that can't be read, is never
/// overwritten. It also keeps which windows are gone, so no path writes their memory again, and
/// the newest reading each part of a window's memory has accepted, so an older one never
/// overwrites it.
public actor MemoryKeeper {
    private var memory: WindowMemory
    private let store: MemoryStore?
    private var mayWrite = false
    private var gone = GoneWindows()
    private var readings: [MemoryPart: ReadingGate] = [:]

    public init(memory: WindowMemory = WindowMemory(), store: MemoryStore? = nil) {
        self.memory = memory
        self.store = store
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

    /// Every change to a window's memory goes through here, with the reading it rests on: a
    /// reading of `window` taken at `readAt`. The change runs only when that part of the window's
    /// memory has accepted no newer reading, and returns nil otherwise; the newer state stands.
    /// Whatever a change wrote for a gone window is dropped in the same step, so a destroyed
    /// window, or one whose app quit, is never written again, whichever path writes and however
    /// late it finishes.
    @discardableResult
    public func record<T>(
        _ window: WindowHandle,
        _ part: MemoryPart,
        readAt: ContinuousClock.Instant,
        _ change: (inout WindowMemory) -> T
    ) -> T? {
        guard !gone.contains(window), readings[part, default: ReadingGate()].admit(window, readAt: readAt) else {
            return nil
        }
        let result = change(&memory)
        let gone = gone
        if !gone.isEmpty, memory.holdsWindow(where: gone.contains) { memory.forget(where: gone.contains) }
        return result
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
        for part in readings.keys { readings[part]?.forget(window) }
    }

    /// The app quit: the memory of its windows goes, for good.
    public func forget(pid: Int32) {
        gone.quit(pid)
        memory.forget(pid: pid)
        for part in readings.keys { readings[part]?.forget(pid: pid) }
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
