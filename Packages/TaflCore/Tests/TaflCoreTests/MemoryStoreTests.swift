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
        return memory
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
}
