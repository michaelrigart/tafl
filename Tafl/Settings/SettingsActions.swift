import AppKit
import TaflCore
import TaflPlatform27

/// What the buttons in Settings do. Tafl writes the config file only in `createStarterFile`, and
/// only when there is none.
final class SettingsActions {
    private static let desktopAndDockURL = URL(
        string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!

    private let model: SettingsModel
    private let platform: any WindowPlatform
    private let table: () -> KeyboardLayoutTable
    private let gap: () -> Double
    private let unobservableApps: () async -> Int
    private let onStarterFileCreated: () -> Void

    init(
        model: SettingsModel,
        platform: any WindowPlatform,
        table: @escaping () -> KeyboardLayoutTable,
        gap: @escaping () -> Double,
        unobservableApps: @escaping () async -> Int,
        onStarterFileCreated: @escaping () -> Void
    ) {
        self.model = model
        self.platform = platform
        self.table = table
        self.gap = gap
        self.unobservableApps = unobservableApps
        self.onStarterFileCreated = onStarterFileCreated
    }

    private var configURL: URL { URL(fileURLWithPath: model.configPath) }

    func openInEditor() {
        NSWorkspace.shared.open(configURL)
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([configURL])
    }

    /// Writes only where nothing exists: `.withoutOverwriting` refuses an existing file, a link
    /// included, even if one appeared since Settings last looked.
    func createStarterFile() {
        model.starterFileError = nil
        do {
            try FileManager.default.createDirectory(
                at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(StarterFile.text(table: table()).utf8).write(to: configURL, options: .withoutOverwriting)
            Log.config.notice("Starter file created")
            // Reading it now updates Overview at once; the watcher would do it a moment later.
            onStarterFileCreated()
        } catch {
            Log.config.notice("Starter file not created: \(error.localizedDescription, privacy: .private)")
            model.starterFileError = "The starter file could not be created. A config file may already exist."
        }
    }

    func openDesktopAndDockSettings() {
        NSWorkspace.shared.open(Self.desktopAndDockURL)
    }

    func openAccessibilitySettings() {
        OnboardingWindow.openAccessibilitySettings()
    }

    /// Builds the layout snippet from the windows on the current Space, shows it and copies it.
    func capture() async {
        model.captureNote = nil
        model.capturedSnippet = nil
        guard model.trusted else {
            model.captureNote = "Accessibility permission is needed to see the windows."
            return
        }
        // Read only to build the snippet: nothing is recorded from it.
        async let windows = platform.visibleWindows(take: { $0 })
        async let displays = platform.usableDisplays()
        let snippet = CaptureBuilder.snippet(windows: await windows, displays: await displays, gap: gap())
        model.capturedSnippet = snippet
        copy(snippet)
        Log.ui.notice("Arrangement captured")
    }

    func copyCaptured() {
        if let snippet = model.capturedSnippet { copy(snippet) }
    }

    func copyDiagnostics() async {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let report = Diagnostics.report(
            macOS: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            displayCount: await platform.usableDisplays().count,
            status: model.status,
            capabilities: await platform.capabilities(),
            unobservableApps: await unobservableApps(),
            recentFailures: model.recentFailures)
        copy(report)
        model.diagnosticsCopied = true
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
