import AppKit

/// Starts a new copy of Tafl and quits this one. The new copy starts only after this process has
/// exited, so it never meets this one and hands over to it: that would leave no copy running.
enum Relaunch {
    private static let script = #"while kill -0 "$1" 2>/dev/null; do sleep 0.1; done; exec /usr/bin/open "$2""#

    static func perform() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Log.app.notice("Could not start the relaunch; Tafl keeps running")
            return
        }
        Log.app.notice("Relaunching Tafl")
        NSApp.terminate(nil)
    }
}
