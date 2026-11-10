import AppKit
import Synchronization

/// Starts a new copy of Tafl and quits this one. The new copy starts only after this process has
/// exited, so it never meets this one and hands over to it: that would leave no copy running.
enum Relaunch {
    private static let script = #"while kill -0 "$1" 2>/dev/null; do sleep 0.1; done; exec /usr/bin/open "$2""#

    private static let started = Mutex(false)

    /// Returns false, and leaves Tafl running, when the new copy could not be scheduled. The quit is
    /// scheduled on the run loop, not made in the caller's main-queue job, so the shutdown can run
    /// while AppKit waits for it. A process starts one helper at most: a later call returns true
    /// without starting another.
    @discardableResult
    static func perform() -> Bool {
        guard started.withLock({ !$0 }) else { return true }
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
            return false
        }
        started.withLock { $0 = true }
        Log.app.notice("Relaunching Tafl")
        RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        return true
    }
}
