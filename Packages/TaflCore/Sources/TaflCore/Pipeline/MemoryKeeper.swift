import Foundation

/// What the memory holds that belongs to no window.
public struct GeneralMemory: Sendable {
    public var activeLayout: String?
    /// The displays, with their geometry, when Tafl last ran or last settled a change.
    public var lastDisplays: [Display]
}

/// Keeps the window memory's store. It writes only after a load that left the file replaceable,
/// so a file written by another version, or one that can't be read, is never overwritten. The
/// memory of each window lives in the window owner, which alone changes it; the keeper loads it
/// there and saves it from there, with what belongs to no window.
public actor MemoryKeeper {
    private let owner: WindowOwner
    private let store: MemoryStore?
    private var mayWrite = false
    private var general = GeneralMemory(activeLayout: nil, lastDisplays: [])
    private var savedAt: Date?

    public init(owner: WindowOwner, store: MemoryStore? = nil) {
        self.owner = owner
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
            adopt(loaded)
            mayWrite = true
        case .fresh, .recoveredFromCorrupt:
            adopt(WindowMemory())
            mayWrite = true
        case .refused, .unavailable:
            adopt(WindowMemory())
            mayWrite = false
        }
        return result
    }

    private func adopt(_ memory: WindowMemory) {
        owner.loadWindows(from: memory)
        general = GeneralMemory(activeLayout: memory.activeLayout, lastDisplays: memory.lastDisplays)
        savedAt = memory.savedAt
    }

    /// The whole memory as it stands.
    public func read() -> WindowMemory {
        var memory = owner.windowMemory
        memory.activeLayout = general.activeLayout
        memory.lastDisplays = general.lastDisplays
        memory.savedAt = savedAt
        return memory
    }

    /// Changes what belongs to no window: the active layout and the displays.
    public func update<T>(_ change: (inout GeneralMemory) -> T) -> T {
        change(&general)
    }

    /// Saves nothing when the last load must not be written over, or there is no store. The
    /// error is the store's: a `MemoryStoreError`, or the file system's. A save records when it
    /// was made.
    public func save() -> Result<Void, any Error> {
        guard let store, mayWrite else { return .success(()) }
        savedAt = Date()
        let memory = read()
        return Result { try store.save(memory) }
    }
}
