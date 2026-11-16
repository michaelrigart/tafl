import Foundation

public enum MemoryLoad: Equatable, Sendable {
    case fresh
    case loaded(WindowMemory)
    case recoveredFromCorrupt
    case refused(version: Int)
    /// The file exists but could be neither read nor moved aside. Nothing is written while it stays that way.
    case unavailable
}

public enum MemoryStoreError: Error, Equatable, Sendable {
    /// The file on disk was written by another version of Tafl and is left untouched.
    case unsupportedVersion(Int)
    /// The file exists but cannot be read, so it is not overwritten.
    case unreadable
}

public final class MemoryStore: Sendable {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    private struct VersionProbe: Decodable {
        var version: Int
    }

    private var corruptURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("memory.corrupt.json")
    }

    public func load() -> MemoryLoad {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .fresh
        } catch {
            return moveCorruptAside()
        }
        guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: data) else {
            return moveCorruptAside()
        }
        guard probe.version == WindowMemory.fileVersion else { return .refused(version: probe.version) }
        guard let memory = try? JSONDecoder().decode(WindowMemory.self, from: data) else {
            return moveCorruptAside()
        }
        return .loaded(memory)
    }

    public func save(_ memory: WindowMemory) throws {
        do {
            let existing = try Data(contentsOf: fileURL)
            if let probe = try? JSONDecoder().decode(VersionProbe.self, from: existing),
               probe.version != WindowMemory.fileVersion {
                throw MemoryStoreError.unsupportedVersion(probe.version)
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
        } catch let error as MemoryStoreError {
            throw error
        } catch {
            throw MemoryStoreError.unreadable
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(memory.droppingUnstableHandles())
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    private func moveCorruptAside() -> MemoryLoad {
        let manager = FileManager.default
        try? manager.removeItem(at: corruptURL)
        do {
            try manager.moveItem(at: fileURL, to: corruptURL)
            return .recoveredFromCorrupt
        } catch {
            return .unavailable
        }
    }
}
