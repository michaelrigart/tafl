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
        await keeper.recordPlacement(keeperWindow, readAt: .now) { $0.openChain(before: rect(1, 2, 3, 4), on: displayA) }
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
        for gone in [keeperWindow, quitApp] {
            await keeper.recordPlacement(gone, readAt: .now) { $0.openChain(before: rect(1, 2, 3, 4), on: displayA) }
            await keeper.recordLastKnown(gone, frame: rect(1, 2, 3, 4), display: displayA, setup: DisplaySetup([displayA]), readAt: .now)
        }
        #expect(await keeper.read() == WindowMemory())
        await keeper.processStarted(pid: 200)
        await keeper.recordPlacement(quitApp, readAt: .now) { $0.openChain(before: rect(1, 2, 3, 4), on: displayA) }
        #expect(await keeper.read().restore[quitApp] != nil)
    }

    // MARK: Readings

    @Test func anOlderReadingLeavesANewerLastKnownFrame() async {
        let keeper = MemoryKeeper()
        let setup = DisplaySetup([displayA])
        let older = ContinuousClock.now
        let newer = older.advanced(by: .milliseconds(1))
        await keeper.recordLastKnown(window, frame: rect(0, 25, 500, 775), display: displayA, setup: setup, readAt: newer)
        let recorded = await keeper.recordLastKnown(
            window, frame: rect(100, 100, 400, 300), display: displayA, setup: setup, readAt: older
        )
        #expect(!recorded)
        #expect(await keeper.read().lastKnown(window, setup: setup)?.relative == rect(0, 25, 500, 775).relative(to: v))
    }

    @Test func aPlacementChangesOnlyFromAReadingAsNewAsTheWindowsNewest() async {
        let readings = WindowReadings()
        let keeper = MemoryKeeper(readings: readings)
        let older = ContinuousClock.now
        let newer = older.advanced(by: .milliseconds(1))
        let placed = PlacedRecord(
            action: .leftHalf, layout: nil, placement: .leftHalf, cycleStep: 0,
            achieved: rect(0, 25, 500, 775), display: displayA.identity
        )
        _ = readings.judge(window, FrameReading(frame: rect(0, 25, 500, 775), readAt: newer))
        let accepted: Void? = await keeper.recordPlacement(window, readAt: newer) { placement in
            placement.openChain(before: rect(1, 2, 3, 4), on: displayA)
            placement.recordPlaced(placed)
        }
        let refused: Void? = await keeper.recordPlacement(window, readAt: older) { $0.recordExternalChange() }
        #expect(accepted != nil)
        #expect(refused == nil)
        #expect(await keeper.read().placement(of: window) == WindowPlacement(placed: placed, restore: RestoreRecord(
            frame: rect(1, 2, 3, 4), display: displayA.identity, visibleFrame: v, chainOpen: true
        )))
    }

    @Test func aNewerLastKnownFrameDoesNotHoldAnOlderPlacementBack() async {
        let keeper = MemoryKeeper()
        let older = ContinuousClock.now
        let newer = older.advanced(by: .milliseconds(1))
        await keeper.recordLastKnown(window, frame: rect(0, 25, 500, 775), display: displayA, setup: DisplaySetup([displayA]), readAt: newer)
        let placement: Void? = await keeper.recordPlacement(window, readAt: older) {
            $0.openChain(before: rect(1, 2, 3, 4), on: displayA)
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
