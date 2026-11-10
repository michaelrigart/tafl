import Foundation
import Testing
@testable import TaflPlatform27

private let fastTiming = RelaunchHelper.Timing(pollInterval: 0.02, dropPolls: 10, confirmPolls: 10, stablePolls: 2, attempts: 3)

/// Fake `open` and `lsappinfo` in a temporary directory, with state in files. `open` logs each call and
/// takes its outcome from the first line of `open-results` (`ok` starts a copy, `fail` exits 1, `none`
/// exits 0 but starts nothing; an empty file means `ok`). A started copy is this test process, which is
/// alive and has another pid than the old copy. `lsappinfo` lists a stale entry for the old copy while
/// `stale-polls` is above 0 (each `find` uses one; `forever` never runs out) and the new copy once started.
private struct Fakes {
    let directory: URL
    let oldPID: Int32
    var open: String { directory.appending(path: "open").path }
    var lsappinfo: String { directory.appending(path: "lsappinfo").path }
    var openLog: [String] {
        ((try? String(contentsOf: directory.appending(path: "open.log"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    init(oldPID: Int32, openResults: [String] = [], stalePolls: String = "0") throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "relaunch-\(UUID().uuidString)")
        self.oldPID = oldPID
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try openResults.map { $0 + "\n" }.joined().write(to: directory.appending(path: "open-results"), atomically: true, encoding: .utf8)
        try stalePolls.write(to: directory.appending(path: "stale-polls"), atomically: true, encoding: .utf8)
        let newPID = ProcessInfo.processInfo.processIdentifier
        try write("open", """
            #!/bin/sh
            d="\(directory.path)"
            echo "$@" >> "$d/open.log"
            result=$(head -n 1 "$d/open-results")
            tail -n +2 "$d/open-results" > "$d/open-results.next"; mv "$d/open-results.next" "$d/open-results"
            case "$result" in
              fail) exit 1 ;;
              none) exit 0 ;;
              *) echo \(newPID) > "$d/new-pid" ;;
            esac
            """)
        try write("lsappinfo", """
            #!/bin/sh
            d="\(directory.path)"
            case "$1" in
              find)
                polls=$(cat "$d/stale-polls")
                if [ "$polls" = forever ]; then echo 'ASN:0x0-0x1-"Tafl":'
                elif [ "$polls" -gt 0 ]; then echo 'ASN:0x0-0x1-"Tafl":'; echo $((polls-1)) > "$d/stale-polls"; fi
                if [ -f "$d/new-pid" ]; then echo 'ASN:0x0-0x2-"Tafl":'; fi ;;
              info)
                case "$4" in
                  ASN:0x0-0x1) echo '"pid"=\(oldPID)' ;;
                  ASN:0x0-0x2) echo "\\"pid\\"=$(cat "$d/new-pid")" ;;
                esac ;;
            esac
            """)
    }

    private func write(_ name: String, _ text: String) throws {
        let url = directory.appending(path: name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func helper(timing: RelaunchHelper.Timing = fastTiming) -> RelaunchHelper {
        RelaunchHelper(open: open, lsappinfo: lsappinfo, timing: timing)
    }

    func run(timing: RelaunchHelper.Timing = fastTiming) async -> Bool? {
        let command = helper(timing: timing).invocation(oldPID: oldPID, bundlePath: "/Applications/Tafl.app", bundleID: "com.example.tafl")
        return await ChildExitStatus(executable: command.executable, arguments: command.arguments, timeout: 20).run()
    }
}

/// A pid that no process has: a child that has already exited.
private func exitedPID() throws -> Int32 {
    let child = Process()
    child.executableURL = URL(filePath: "/usr/bin/true")
    try child.run()
    child.waitUntilExit()
    return child.processIdentifier
}

@Test(.timeLimit(.minutes(1))) func aStaleListingThatClearsLetsOneOpenStartTheNewCopy() async throws {
    let fakes = try Fakes(oldPID: exitedPID(), stalePolls: "4")
    #expect(await fakes.run() == true)
    #expect(fakes.openLog == ["/Applications/Tafl.app"])
}

@Test(.timeLimit(.minutes(1))) func anOpenThatFailsOnceIsRepeatedUntilACopyIsRunning() async throws {
    let fakes = try Fakes(oldPID: exitedPID(), openResults: ["fail", "ok"])
    #expect(await fakes.run() == true)
    #expect(fakes.openLog.count == 2)
}

@Test(.timeLimit(.minutes(1))) func anOpenThatNeverStartsACopyGivesUpAfterTheAttemptLimit() async throws {
    let fakes = try Fakes(oldPID: exitedPID(), openResults: ["none", "none", "none", "none", "none"])
    #expect(await fakes.run() == false)
    #expect(fakes.openLog.count == fastTiming.attempts)
}

@Test(.timeLimit(.minutes(1))) func aListingOfTheOldCopyAloneIsNotANewCopy() async throws {
    let fakes = try Fakes(oldPID: exitedPID(), openResults: ["none", "none"], stalePolls: "forever")
    let timing = RelaunchHelper.Timing(pollInterval: 0.02, dropPolls: 3, confirmPolls: 3, stablePolls: 2, attempts: 2)
    #expect(await fakes.run(timing: timing) == false)
    #expect(fakes.openLog.count == 2)
}

@Test(.timeLimit(.minutes(1))) func nothingIsOpenedWhileTheOldProcessIsStillRunning() async throws {
    let old = Process()
    old.executableURL = URL(filePath: "/bin/sleep")
    old.arguments = ["60"]
    try old.run()
    defer { if old.isRunning { old.terminate() } }
    let fakes = try Fakes(oldPID: old.processIdentifier)
    let helper = Task { await fakes.run() }
    try await Task.sleep(for: .milliseconds(400))
    #expect(fakes.openLog.isEmpty)
    old.terminate()
    old.waitUntilExit()
    #expect(await helper.bounded() == true)
    #expect(fakes.openLog.count == 1)
}
