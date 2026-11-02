import AppKit
import TaflCore
import TaflPlatform27

@main
final class TaflApp: NSObject, NSApplicationDelegate {
    private static let bundleID = "com.michaelrigart.tafl"
    private var root: CompositionRoot?

    static func main() {
        let app = NSApplication.shared
        let delegate = TaflApp()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let probeArguments = Probe.arguments(from: CommandLine.arguments) {
            Probe.run(arguments: probeArguments)
            return
        }
        #endif
        if let running = otherInstance() {
            Log.app.notice("Another Tafl is running; handing over to it")
            hand(over: running)
            return
        }
        let root = CompositionRoot()
        self.root = root
        root.start()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        root?.syncPermission()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        root?.reopen()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let root else { return .terminateNow }
        Task {
            await root.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func otherInstance() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
            .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    }

    /// Opening the running copy again makes it receive a reopen, which opens its Settings.
    private func hand(over running: NSRunningApplication) {
        guard let url = running.bundleURL else {
            NSApp.terminate(nil)
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
