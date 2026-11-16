import AppKit

/// What the platform needs to know about a running app, read without asking the app.
struct AppInfo27: Sendable, Equatable {
    var pid: Int32
    var bundleID: String?
    var name: String
    var isHidden: Bool

    init(pid: Int32, bundleID: String?, name: String, isHidden: Bool) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.isHidden = isHidden
    }

    init(_ app: NSRunningApplication) {
        self.init(
            pid: app.processIdentifier,
            bundleID: app.bundleIdentifier,
            name: app.localizedName ?? app.bundleIdentifier ?? "App",
            isHidden: app.isHidden)
    }

    static func running(pid: Int32) -> AppInfo27? {
        NSRunningApplication(processIdentifier: pid).map(AppInfo27.init)
    }

    /// Apps with a Dock icon and menu bar: the only ones whose windows Tafl places.
    @MainActor
    static func regularApps() -> [AppInfo27] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .map(AppInfo27.init)
    }

    @MainActor
    static func frontmost() -> AppInfo27? {
        NSWorkspace.shared.frontmostApplication.map(AppInfo27.init)
    }
}
