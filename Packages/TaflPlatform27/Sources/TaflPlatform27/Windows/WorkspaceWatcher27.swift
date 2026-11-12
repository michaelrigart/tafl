import AppKit

/// Launch and quit notifications for as long as it runs. Every app quit is reported; only regular apps
/// are observed when they launch, and an app that becomes regular later is met by a query.
@MainActor
final class WorkspaceWatcher27 {
    private var tokens: [any NSObjectProtocol] = []

    func start(observation: WindowObservation27) {
        stop()
        let center = NSWorkspace.shared.notificationCenter
        tokens = [
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
                guard let app = Self.app(in: note), app.activationPolicy == .regular else { return }
                let info = AppInfo27(app)
                Task { await observation.appLaunched(info) }
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
                guard let app = Self.app(in: note) else { return }
                let pid = app.processIdentifier
                Task { await observation.appQuit(pid: pid) }
            },
        ]
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        tokens.forEach(center.removeObserver)
        tokens = []
    }

    private nonisolated static func app(in note: Notification) -> NSRunningApplication? {
        note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    }
}
