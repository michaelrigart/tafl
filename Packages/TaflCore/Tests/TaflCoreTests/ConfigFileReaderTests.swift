import Foundation
import Testing
@testable import TaflCore

final class ConfigFileReaderTests {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("tafl-config-\(UUID().uuidString)", isDirectory: true)

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func path(_ name: String) -> String { directory.appendingPathComponent(name).path }

    func describe(_ name: String) -> String {
        switch ConfigFileReader.read(path: path(name)) {
        case .missing: "missing"
        case .text(let text): "text: \(text)"
        case .unreadable(let reason): "unreadable: \(reason)"
        }
    }

    @Test func noFileIsMissing() {
        #expect(describe("config.toml") == "missing")
    }

    @Test func aFileIsItsText() throws {
        try "gap = 4\n".write(toFile: path("config.toml"), atomically: true, encoding: .utf8)
        #expect(describe("config.toml") == "text: gap = 4\n")
    }

    @Test func aLinkIsFollowedToItsText() throws {
        try "step = 10\n".write(toFile: path("real.toml"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: path("config.toml"), withDestinationPath: "real.toml")
        #expect(describe("config.toml") == "text: step = 10\n")
    }

    @Test func aLinkToNothingIsUnreadableNotMissing() throws {
        try FileManager.default.createSymbolicLink(atPath: path("config.toml"), withDestinationPath: "gone.toml")
        #expect(describe("config.toml") == "unreadable: config.toml points to a missing file")
    }

    @Test func aDirectoryIsUnreadable() throws {
        try FileManager.default.createDirectory(atPath: path("config.toml"), withIntermediateDirectories: false)
        #expect(describe("config.toml") == "unreadable: config.toml can't be read")
    }

    @Test func aFileThatIsNotTextIsUnreadable() throws {
        try Data([0xFF, 0xFE, 0xFD]).write(to: URL(fileURLWithPath: path("config.toml")))
        #expect(describe("config.toml") == "unreadable: config.toml isn't valid UTF-8 text")
    }
}
