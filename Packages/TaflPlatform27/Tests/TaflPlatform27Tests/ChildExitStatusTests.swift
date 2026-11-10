import Foundation
import Testing
@testable import TaflPlatform27

@Test(.timeLimit(.minutes(1))) func exitStatusZeroIsTrue() async {
    let check = ChildExitStatus(executable: URL(filePath: "/usr/bin/true"), arguments: [], timeout: 5)
    #expect(await check.run() == true)
}

@Test(.timeLimit(.minutes(1))) func exitStatusOneIsFalse() async {
    let check = ChildExitStatus(executable: URL(filePath: "/usr/bin/false"), arguments: [], timeout: 5)
    #expect(await check.run() == false)
}

@Test(.timeLimit(.minutes(1))) func anyOtherExitStatusIsNil() async {
    let check = ChildExitStatus(executable: URL(filePath: "/bin/sh"), arguments: ["-c", "exit 2"], timeout: 5)
    #expect(await check.run() == nil)
}

@Test(.timeLimit(.minutes(1))) func aChildKilledBySignalOneIsNotAnExitStatusOne() async {
    let check = ChildExitStatus(executable: URL(filePath: "/bin/sh"), arguments: ["-c", "kill -HUP $$"], timeout: 5)
    #expect(await check.run() == nil)
}

@Test(.timeLimit(.minutes(1))) func aMissingExecutableIsNil() async {
    let check = ChildExitStatus(executable: URL(filePath: "/nonexistent/tafl"), arguments: [], timeout: 5)
    #expect(await check.run() == nil)
}

@Test(.timeLimit(.minutes(1))) func aChildThatDoesNotExitInTimeIsNilAndTerminated() async throws {
    let pidFile = FileManager.default.temporaryDirectory.appending(path: "tafl-child-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: pidFile) }
    let check = ChildExitStatus(
        executable: URL(filePath: "/bin/sh"),
        arguments: ["-c", "echo $$ > \"$1\"; exec /bin/sleep 5", "sh", pidFile.path],
        timeout: 0.5)
    #expect(await check.run() == nil)
    let text = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    let pid = try #require(pid_t(text))
    #expect(kill(pid, 0) == -1 && errno == ESRCH)
}

@Test(.timeLimit(.minutes(1))) func aChildThatIgnoresTerminateIsKilledSoonAfterTheTimeout() async throws {
    let pidFile = FileManager.default.temporaryDirectory.appending(path: "tafl-child-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: pidFile) }
    let check = ChildExitStatus(
        executable: URL(filePath: "/bin/sh"),
        arguments: ["-c", "echo $$ > \"$1\"; trap '' TERM; while :; do /bin/sleep 0.05; done", "sh", pidFile.path],
        timeout: 0.5)
    let start = ContinuousClock.now
    #expect(await check.run() == nil)
    #expect(ContinuousClock.now - start < .seconds(3))
    let text = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    let pid = try #require(pid_t(text))
    #expect(kill(pid, 0) == -1 && errno == ESRCH)
}
