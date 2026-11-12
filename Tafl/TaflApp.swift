import AppKit
import TaflCore
import TaflPlatform27

@main
final class TaflApp: NSObject, NSApplicationDelegate {
    private static let bundleID = "com.michaelrigart.tafl"
    private var root: CompositionRoot?

    static func main() {
        if CommandLine.arguments.contains(Permission27.checkArgument) {
            exit(AXIsProcessTrusted() ? 0 : 1)
        }
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
        if let running = earlierInstance() {
            Log.app.notice("An earlier Tafl is running; handing over to it")
            hand(over: running)
            return
        }
        startRoot()
    }

    private func startRoot() {
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

    /// The copy that started first keeps running; a copy of this one that started together with it
    /// settles on the lower process id.
    private func earlierInstance() -> NSRunningApplication? {
        let own = (launchDate: NSRunningApplication.current.launchDate, pid: ProcessInfo.processInfo.processIdentifier)
        return NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first {
            !$0.isTerminated && $0.processIdentifier != own.pid
                && InstanceOrder.defers(own: own, to: (launchDate: $0.launchDate, pid: $0.processIdentifier))
        }
    }

    /// Opening the running copy again makes it receive a reopen, which opens its Settings. If that
    /// fails, this copy carries on rather than leave none running.
    private func hand(over running: NSRunningApplication) {
        guard let url = running.bundleURL else {
            startRoot()
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            Task { @MainActor in
                if error == nil {
                    NSApp.terminate(nil)
                } else {
                    Log.app.notice("Could not hand over to the running Tafl; starting this copy")
                    self.startRoot()
                }
            }
        }
    }
}
