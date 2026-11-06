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

    private func makeKeeper() -> (MemoryKeeper, WindowOwner) {
        let owner = WindowOwner(adjustments: [])
        return (MemoryKeeper(owner: owner, store: store), owner)
    }

    /// Changes the window's memory as a request does: a reading begins it, and its end records.
    private func change(_ owner: WindowOwner) {
        let snapshot = TaflCoreTests.window(1, frame: rect(1, 2, 3, 4))
        let start = owner.beginRequest(snapshot)
        let unchanged = Applied.unchanged(leftHalfRequest(for: snapshot.handle), frame: rect(1, 2, 3, 4), display: displayA)
        owner.endRequest(start.ticket, recording: unchanged)
    }

    private func isSuccess(_ result: Result<Void, any Error>) -> Bool {
        if case .success = result { return true }
        return false
    }

    @Test func saveBeforeAnyLoadWritesNothing() async {
        let (keeper, owner) = makeKeeper()
        change(owner)
        #expect(isSuccess(await keeper.save()))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func saveAfterAFreshLoadWrites() async throws {
        let (keeper, owner) = makeKeeper()
        #expect(await keeper.load() == .fresh)
        change(owner)
        #expect(isSuccess(await keeper.save()))
        guard case .loaded(let saved) = store.load() else { Issue.record("Nothing was written"); return }
        #expect(saved.restore[window]?.frame == rect(1, 2, 3, 4))
    }

    @Test func saveAfterALoadWritesWhatWasLoadedPlusChanges() async throws {
        var existing = WindowMemory()
        existing.activeLayout = "Desk"
        try store.save(existing)
        let (keeper, owner) = makeKeeper()
        #expect(await keeper.load() == .loaded(existing))
        #expect(await keeper.read() == existing)
        change(owner)
        #expect(isSuccess(await keeper.save()))
        guard case .loaded(let saved) = store.load() else { Issue.record("Nothing was written"); return }
        #expect(saved.activeLayout == "Desk")
        #expect(saved.restore[window] != nil)
    }

    @Test func saveAfterARecoveredLoadWrites() async throws {
        try writeFile(Data("{not json".utf8))
        let (keeper, owner) = makeKeeper()
        #expect(await keeper.load() == .recoveredFromCorrupt)
        #expect(await keeper.read() == WindowMemory())
        change(owner)
        #expect(isSuccess(await keeper.save()))
        guard case .loaded(let saved) = store.load() else { Issue.record("Nothing was written"); return }
        #expect(saved.restore[window] != nil)
    }

    @Test func saveAfterARefusedLoadWritesNothing() async throws {
        let original = Data(#"{"version": 2}"#.utf8)
        try writeFile(original)
        let (keeper, owner) = makeKeeper()
        #expect(await keeper.load() == .refused(version: 2))
        change(owner)
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
        let (keeper, owner) = makeKeeper()
        #expect(await keeper.load() == .unavailable)
        change(owner)
        #expect(isSuccess(await keeper.save()))
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func aFailedLoadResetsAnEarlierLoadsPermissionToWrite() async throws {
        let (keeper, _) = makeKeeper()
        #expect(await keeper.load() == .fresh)
        try writeFile(Data(#"{"version": 2}"#.utf8))
        #expect(await keeper.load() == .refused(version: 2))
        #expect(await keeper.read() == WindowMemory())
        #expect(isSuccess(await keeper.save()))
        #expect(try Data(contentsOf: file) == Data(#"{"version": 2}"#.utf8))
    }

    @Test func saveReturnsTheStoresError() async throws {
        let (keeper, _) = makeKeeper()
        #expect(await keeper.load() == .fresh)
        try writeFile(Data(#"{"version": 2}"#.utf8))
        guard case .failure(let error) = await keeper.save() else { Issue.record("Expected the store's refusal"); return }
        #expect(error as? MemoryStoreError == .unsupportedVersion(2))
    }

    @Test func aSaveRecordsWhenItWasMade() async throws {
        let (keeper, _) = makeKeeper()
        #expect(await keeper.load() == .fresh)
        let before = Date()
        #expect(isSuccess(await keeper.save()))
        let after = Date()
        guard case .loaded(let saved) = store.load() else { Issue.record("Nothing was written"); return }
        let savedAt = try #require(saved.savedAt)
        #expect(before <= savedAt && savedAt <= after)
    }

    @Test func aLoadHandsTheOwnerItsWindowsAndAReadAddsWhatBelongsToNoWindow() async throws {
        var existing = WindowMemory(activeLayout: "Desk", lastDisplays: [displayA], savedAt: Date(timeIntervalSince1970: 1))
        existing.openChain(window, before: rect(1, 2, 3, 4), on: displayA)
        try store.save(existing)
        let (keeper, owner) = makeKeeper()
        #expect(await keeper.load() == .loaded(existing))
        #expect(owner.windowMemory == WindowMemory(restore: existing.restore))
        #expect(await keeper.read() == existing)
    }

    @Test func withoutAStoreSaveSucceeds() async {
        let owner = WindowOwner(adjustments: [])
        let keeper = MemoryKeeper(owner: owner)
        change(owner)
        #expect(isSuccess(await keeper.save()))
    }
}
