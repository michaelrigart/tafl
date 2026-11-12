import Foundation
import Testing
@testable import TaflCore

final class MemoryStoreTests {
    let directory: URL
    let file: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tafl-memory-\(UUID().uuidString)", isDirectory: true)
        file = directory.appendingPathComponent("state", isDirectory: true).appendingPathComponent("memory.json")
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func sampleMemory() -> WindowMemory {
        let w1 = WindowHandle(pid: 100, windowID: 1, isStable: true)
        let w2 = WindowHandle(pid: 200, windowID: 7, isStable: true)
        var memory = WindowMemory()
        memory.openChain(w1, before: rect(100, 100, 400, 300), on: displayB)
        memory.recordPlaced(
            w1,
            PlacedRecord(
                action: .leftHalf,
                layout: "Desk",
                placement: .leftHalf,
                cycleStep: 2,
                achieved: rect(0, 25, 500, 775),
                display: displayA.identity
            )
        )
        memory.recordPlaced(
            w2,
            PlacedRecord(
                action: nil,
                layout: nil,
                placement: nil,
                cycleStep: 0,
                achieved: rect(10, 35, 400, 300),
                display: displayB.identity
            )
        )
        memory.recordLastKnown(w1, frame: rect(100, 100, 400, 300), display: displayA, setup: DisplaySetup([displayA]))
        memory.recordLastKnown(w2, frame: rect(1200, 150, 800, 600), display: displayB, setup: DisplaySetup([displayA, displayB]))
        memory.activeLayout = "Desk"
        memory.lastDisplays = [displayA, displayB]
        memory.savedAt = Date(timeIntervalSince1970: 1_800_000_000)
        return memory
    }

    /// A file written before Tafl kept a save date still loads, without one.
    @Test func aFileWithoutASaveDateStillLoads() throws {
        let store = MemoryStore(fileURL: file)
        var memory = sampleMemory()
        memory.savedAt = nil
        try store.save(memory)
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(object["savedAt"] == nil)
        #expect(store.load() == .loaded(memory))
    }

    @Test func missingFileIsFresh() {
        #expect(MemoryStore(fileURL: file).load() == .fresh)
    }

    @Test func roundTrips() throws {
        let store = MemoryStore(fileURL: file)
        let memory = sampleMemory()
        try store.save(memory)
        #expect(store.load() == .loaded(memory))
        let loaded = try #require({ if case .loaded(let m) = store.load() { m } else { nil } }())
        #expect(loaded.lastDisplays == [displayA, displayB])
        #expect(loaded.lastSetup == DisplaySetup([displayA, displayB]))
    }

    @Test func fileIsVersionedReadableJSON() throws {
        let store = MemoryStore(fileURL: file)
        try store.save(sampleMemory())
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(object["version"] as? Int == 1)
        let placed = try #require(object["placed"] as? [[String: Any]])
        #expect(placed.count == 2)
        #expect(placed[0]["window"] != nil && placed[0]["record"] != nil)
    }

    @Test func outputIsStable() throws {
        let store = MemoryStore(fileURL: file)
        try store.save(sampleMemory())
        let first = try Data(contentsOf: file)
        for _ in 0..<5 {
            try store.save(sampleMemory())
            #expect(try Data(contentsOf: file) == first)
        }
    }

    @Test func saveCreatesTheDirectory() throws {
        #expect(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
        try MemoryStore(fileURL: file).save(WindowMemory())
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func saveLeavesNoTemporaryFiles() throws {
        try MemoryStore(fileURL: file).save(sampleMemory())
        let names = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        #expect(names == ["memory.json"])
    }

    @Test func unknownVersionIsRefusedAndNeverOverwritten() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"{"version": 2}"#.utf8)
        try original.write(to: file)
        let store = MemoryStore(fileURL: file)
        #expect(store.load() == .refused(version: 2))
        #expect(throws: MemoryStoreError.self) { try store.save(sampleMemory()) }
        #expect(try Data(contentsOf: file) == original)
        #expect(store.load() == .refused(version: 2))
    }

    @Test func corruptFileIsMovedAside() throws {
        let directory = file.deletingLastPathComponent()
        let corrupt = directory.appendingPathComponent("memory.corrupt.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("older".utf8).write(to: corrupt)
        try Data("{not json".utf8).write(to: file)
        let store = MemoryStore(fileURL: file)
        #expect(store.load() == .recoveredFromCorrupt)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try Data(contentsOf: corrupt) == Data("{not json".utf8))
        #expect(store.load() == .fresh)
        try store.save(sampleMemory())
        #expect(store.load() == .loaded(sampleMemory()))
    }

    @Test func fileWithoutAVersionIsCorrupt() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"placed": []}"#.utf8).write(to: file)
        #expect(MemoryStore(fileURL: file).load() == .recoveredFromCorrupt)
        #expect(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().appendingPathComponent("memory.corrupt.json").path))
    }

    @Test func unstableHandlesAreNotSaved() throws {
        let stable = WindowHandle(pid: 100, windowID: 1, isStable: true)
        let unstable = WindowHandle(pid: 100, windowID: 2, isStable: false)
        var memory = WindowMemory()
        let setup = DisplaySetup([displayA])
        for window in [stable, unstable] {
            memory.openChain(window, before: rect(100, 100, 400, 300), on: displayA)
            memory.recordPlaced(
                window,
                PlacedRecord(action: .maximize, layout: nil, placement: .maximize, cycleStep: 0, achieved: v, display: displayA.identity)
            )
            memory.recordLastKnown(window, frame: rect(100, 100, 400, 300), display: displayA, setup: setup)
        }
        let store = MemoryStore(fileURL: file)
        try store.save(memory)
        guard case .loaded(let loaded) = store.load() else {
            Issue.record("expected a loaded memory")
            return
        }
        #expect(Set(loaded.placed.keys) == [stable])
        #expect(Set(loaded.restore.keys) == [stable])
        #expect(loaded.lastKnown(stable, setup: setup) != nil)
        #expect(loaded.lastKnown(unstable, setup: setup) == nil)
    }

    @Test func wellFormedFileOfTheWrongShapeIsCorrupt() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data(#"{"version": 1, "placed": "nope"}"#.utf8)
        try bytes.write(to: file)
        #expect(MemoryStore(fileURL: file).load() == .recoveredFromCorrupt)
        let corrupt = file.deletingLastPathComponent().appendingPathComponent("memory.corrupt.json")
        #expect(try Data(contentsOf: corrupt) == bytes)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aDirectoryInPlaceOfTheFileIsMovedAside() throws {
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        #expect(MemoryStore(fileURL: file).load() == .recoveredFromCorrupt)
        var isDirectory: ObjCBool = false
        let corrupt = file.deletingLastPathComponent().appendingPathComponent("memory.corrupt.json")
        #expect(FileManager.default.fileExists(atPath: corrupt.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aDirectoryInPlaceOfTheFileIsNeverOverwritten() throws {
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        #expect(throws: MemoryStoreError.unreadable) { try MemoryStore(fileURL: file).save(sampleMemory()) }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) && isDirectory.boolValue)
    }

    @Test func anUnreadableFileThatCannotBeMovedIsUnavailableAndNeverOverwritten() throws {
        let parent = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let original = Data("precious".utf8)
        try original.write(to: file)
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
        defer {
            try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
            try? manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        }
        let store = MemoryStore(fileURL: file)
        #expect(store.load() == .unavailable)
        #expect(throws: MemoryStoreError.unreadable) { try store.save(sampleMemory()) }
        try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func emptySetupsDoNotSurviveASave() throws {
        let stable = WindowHandle(pid: 100, windowID: 1, isStable: true)
        let unstable = WindowHandle(pid: 100, windowID: 2, isStable: false)
        let onlyUnstable = DisplaySetup([displayB])
        var memory = WindowMemory()
        memory.recordLastKnown(stable, frame: rect(100, 100, 400, 300), display: displayA, setup: DisplaySetup([displayA]))
        memory.recordLastKnown(unstable, frame: rect(100, 100, 400, 300), display: displayB, setup: onlyUnstable)
        let store = MemoryStore(fileURL: file)
        try store.save(memory)
        var expected = memory
        expected.forget(unstable)
        #expect(expected.lastKnown[onlyUnstable] == nil)
        #expect(store.load() == .loaded(expected))
    }
}
