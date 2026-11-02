import AppKit
import TaflCore

/// Launch and quit of regular apps, and display reconfiguration, for as long as it runs.
@MainActor
final class WorkspaceWatcher27 {
    private var tokens: [any NSObjectProtocol] = []
    private var monitor: ReconfigurationMonitor27?

    func start(observation: WindowObservation27, events: AsyncStream<PlatformEvent>.Continuation) {
        stop()
        let center = NSWorkspace.shared.notificationCenter
        tokens = [
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
                guard let app = Self.regularApp(in: note) else { return }
                let info = AppInfo27(app)
                Task { await observation.appLaunched(info) }
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
                guard let app = Self.regularApp(in: note) else { return }
                let pid = app.processIdentifier
                Task { await observation.appQuit(pid: pid) }
            },
        ]
        monitor = ReconfigurationMonitor27 { phase, _ in
            events.yield(phase == .began ? .reconfigurationBegan : .reconfigurationEnded)
        }
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        tokens.forEach(center.removeObserver)
        tokens = []
        monitor?.invalidate()
        monitor = nil
    }

    private nonisolated static func regularApp(in note: Notification) -> NSRunningApplication? {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        return app?.activationPolicy == .regular ? app : nil
    }
}
