import Foundation
import Testing
@testable import TaflCore

private let keeperWindow = WindowHandle(pid: 100, windowID: 1, isStable: true)

final class MemoryKeeperTests {
    let directory: URL
    let file: URL
    let store: MemoryStore
    let window = keeperWindow

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tafl-keeper-\(UUID().uuidString)", isDirectory: true)
        file = directory.appendingPathComponent("memory.json")
        store = MemoryStore(fileURL: file)
    }

    deinit {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        try? FileManager.default.removeItem(at: directory)
    }

    private func writeFile(_ bytes: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: file)
    }

    private func change(_ keeper: MemoryKeeper) async {
        await keeper.record(keeperWindow, .placement, readAt: .now) {
            $0.openChain(keeperWindow, before: rect(1, 2, 3, 4), on: displayA)
        }
    }

    private func isSuccess(_ result: Result<Void, any Error>) -> Bool {
        if case .success = result { return true }
        return false
    }

    @Test func saveBeforeAnyLoadWritesNothing() async {
        let keeper = MemoryKeeper(store: store)
        await change(keeper)
        #expect(isSuccess(await keeper.save()))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func saveAfterAFreshLoadWrites() async throws {
        let keeper = MemoryKeeper(store: store)
        #expect(await keeper.load() == .fresh)
        await change(keeper)
        #expect(isSuccess(await keeper.save()))
        guard case .loaded(let saved) = store.load() else { Issue.record("Nothing was written"); return }
        #expect(saved.restore[window]?.frame == rect(1, 2, 3, 4))
    }

    @Test func saveAfterALoadWritesWhatWasLoadedPlusChanges() async throws {
        var existing = WindowMemory()
        existing.activeLayout = "Desk"
        try store.save(existing)
        let keeper = MemoryKeeper(store: store)
        #expect(await keeper.load() == .loaded(existing))
        #expect(await keeper.read() == existing)
        await change(keeper)
        #expect(isSuccess(await keeper.save()))
        guard case .loaded(let saved) = store.load() else { Issue.record("Nothing was written"); return }
        #expect(saved.activeLayout == "Desk")
        #expect(saved.restore[window] != nil)
    }

    @Test func saveAfterARecoveredLoadWrites() async throws {
        try writeFile(Data("{not json".utf8))
        let keeper = MemoryKeeper(store: store)
        #expect(await keeper.load() == .recoveredFromCorrupt)
        #expect(await keeper.read() == WindowMemory())
        await change(keeper)
        #expect(isSuccess(await keeper.save()))
        guard case .loaded(let saved) = store.load() else { Issue.record("Nothing was written"); return }
        #expect(saved.restore[window] != nil)
    }

    @Test func saveAfterARefusedLoadWritesNothing() async throws {
        let original = Data(#"{"version": 2}"#.utf8)
        try writeFile(original)
        let keeper = MemoryKeeper(store: store)
        #expect(await keeper.load() == .refused(version: 2))
        await change(keeper)
        // A success, not the store's refusal: the keeper never asked it to write.
        #expect(isSuccess(await keeper.save()))
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func saveAfterAnUnavailableLoadWritesNothing() async throws {
        let original = Data("precious".utf8)
        try writeFile(original)
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        let keeper = MemoryKeeper(store: store)
        #expect(await keeper.load() == .unavailable)
        await change(keeper)
        #expect(isSuccess(await keeper.save()))
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func aFailedLoadResetsAnEarlierLoadsPermissionToWrite() async throws {
        let keeper = MemoryKeeper(store: store)
        #expect(await keeper.load() == .fresh)
        try writeFile(Data(#"{"version": 2}"#.utf8))
        #expect(await keeper.load() == .refused(version: 2))
        #expect(await keeper.read() == WindowMemory())
        #expect(isSuccess(await keeper.save()))
        #expect(try Data(contentsOf: file) == Data(#"{"version": 2}"#.utf8))
    }

    @Test func saveReturnsTheStoresError() async throws {
        let keeper = MemoryKeeper(store: store)
        #expect(await keeper.load() == .fresh)
        try writeFile(Data(#"{"version": 2}"#.utf8))
        guard case .failure(let error) = await keeper.save() else { Issue.record("Expected the store's refusal"); return }
        #expect(error as? MemoryStoreError == .unsupportedVersion(2))
    }

    @Test func aSaveRecordsWhenItWasMade() async throws {
        let keeper = MemoryKeeper(store: store)
        #expect(await keeper.load() == .fresh)
        let before = Date()
        #expect(isSuccess(await keeper.save()))
        let after = Date()
        guard case .loaded(let saved) = store.load() else { Issue.record("Nothing was written"); return }
        let savedAt = try #require(saved.savedAt)
        #expect(before <= savedAt && savedAt <= after)
    }

    @Test func aGoneWindowIsNeverWrittenAgainUntilANewProcessHasItsId() async {
        let keeper = MemoryKeeper()
        let quitApp = WindowHandle(pid: 200, windowID: 1, isStable: true)
        await keeper.forget(keeperWindow)
        await keeper.forget(pid: 200)
        await keeper.record(keeperWindow, .placement, readAt: .now) { $0.openChain(keeperWindow, before: rect(1, 2, 3, 4), on: displayA) }
        await keeper.record(quitApp, .placement, readAt: .now) { $0.openChain(quitApp, before: rect(1, 2, 3, 4), on: displayA) }
        // A change that writes another window drops what it wrote for a gone one too.
        let alive = WindowHandle(pid: 300, windowID: 1, isStable: true)
        await keeper.record(alive, .placement, readAt: .now) { memory in
            memory.openChain(alive, before: rect(1, 2, 3, 4), on: displayA)
            memory.openChain(quitApp, before: rect(1, 2, 3, 4), on: displayA)
        }
        #expect(await keeper.read().restore.keys.sorted { $0.pid < $1.pid } == [alive])
        await keeper.processStarted(pid: 200)
        await keeper.record(quitApp, .placement, readAt: .now) { $0.openChain(quitApp, before: rect(1, 2, 3, 4), on: displayA) }
        #expect(await keeper.read().restore[quitApp] != nil)
    }

    // MARK: Readings

    @Test func anOlderReadingLeavesANewerLastKnownFrame() async {
        let keeper = MemoryKeeper()
        let setup = DisplaySetup([displayA])
        let older = ContinuousClock.now
        let newer = older.advanced(by: .milliseconds(1))
        await keeper.record(window, .lastKnown, readAt: newer) {
            $0.recordLastKnown(keeperWindow, frame: rect(0, 25, 500, 775), display: displayA, setup: setup)
        }
        let refused: Void? = await keeper.record(window, .lastKnown, readAt: older) {
            $0.recordLastKnown(keeperWindow, frame: rect(100, 100, 400, 300), display: displayA, setup: setup)
        }
        #expect(refused == nil)
        #expect(await keeper.read().lastKnown(window, setup: setup)?.relative == rect(0, 25, 500, 775).relative(to: v))
    }

    @Test func anOlderReadingLeavesANewerPlacement() async {
        let keeper = MemoryKeeper()
        let older = ContinuousClock.now
        let newer = older.advanced(by: .milliseconds(1))
        let placed = PlacedRecord(
            action: .leftHalf, layout: nil, placement: .leftHalf, cycleStep: 0,
            achieved: rect(0, 25, 500, 775), display: displayA.identity
        )
        await keeper.record(window, .placement, readAt: newer) { memory in
            memory.openChain(keeperWindow, before: rect(1, 2, 3, 4), on: displayA)
            memory.recordPlaced(keeperWindow, placed)
        }
        await keeper.record(window, .placement, readAt: older) { $0.recordExternalChange(keeperWindow) }
        let after = await keeper.read()
        #expect(after.placed[window] == placed)
        #expect(after.restore[window]?.chainOpen == true)
    }

    @Test func aReadingAsNewAsTheNewestIsAccepted() async {
        let keeper = MemoryKeeper()
        let readAt = ContinuousClock.now
        await keeper.record(window, .placement, readAt: readAt) { $0.openChain(keeperWindow, before: rect(1, 2, 3, 4), on: displayA) }
        let again: Void? = await keeper.record(window, .placement, readAt: readAt) { $0.recordExternalChange(keeperWindow) }
        #expect(again != nil)
        #expect(await keeper.read().restore[window]?.chainOpen == false)
    }

    @Test func eachPartKeepsItsOwnNewestReading() async {
        let keeper = MemoryKeeper()
        let older = ContinuousClock.now
        let newer = older.advanced(by: .milliseconds(1))
        await keeper.record(window, .lastKnown, readAt: newer) {
            $0.recordLastKnown(keeperWindow, frame: rect(0, 25, 500, 775), display: displayA, setup: DisplaySetup([displayA]))
        }
        let placement: Void? = await keeper.record(window, .placement, readAt: older) {
            $0.openChain(keeperWindow, before: rect(1, 2, 3, 4), on: displayA)
        }
        #expect(placement != nil)
        #expect(await keeper.read().restore[window] != nil)
    }

    @Test func withoutAStoreSaveSucceeds() async {
        let keeper = MemoryKeeper()
        await change(keeper)
        #expect(isSuccess(await keeper.save()))
    }
}
