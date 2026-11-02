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

/// Owns the window memory and its store. It writes only after a load that left the file
/// replaceable, so a file written by another version, or one that can't be read, is never
/// overwritten. It also keeps which windows are gone, so no path writes their memory again.
public actor MemoryKeeper {
    private var memory: WindowMemory
    private let store: MemoryStore?
    private var mayWrite = false
    private var gone = GoneWindows()

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

    /// Every change goes through here. Whatever a change wrote for a gone window is dropped in the
    /// same step, so a destroyed window, or one whose app quit, is never written again, whichever
    /// path writes and however late it finishes.
    public func update<T>(_ change: (inout WindowMemory) -> T) -> T {
        let result = change(&memory)
        let gone = gone
        if !gone.isEmpty, memory.holdsWindow(where: gone.contains) { memory.forget(where: gone.contains) }
        return result
    }

    /// The window was destroyed: its memory goes, for good.
    public func forget(_ window: WindowHandle) {
        gone.destroyed(window)
        memory.forget(window)
    }

    /// The app quit: the memory of its windows goes, for good.
    public func forget(pid: Int32) {
        gone.quit(pid)
        memory.forget(pid: pid)
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
