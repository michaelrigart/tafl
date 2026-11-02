import Foundation

/// Owns the window memory and its store. It writes only after a load that left the file
/// replaceable, so a file written by another version, or one that can't be read, is never
/// overwritten.
public actor MemoryKeeper {
    private var memory: WindowMemory
    private let store: MemoryStore?
    private var mayWrite = false

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

    public func update<T>(_ change: (inout WindowMemory) -> T) -> T {
        change(&memory)
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
