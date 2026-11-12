import AppKit
import SwiftUI

/// The Settings window: a sidebar of sections beside the selected one.
final class SettingsWindow {
    private let model: SettingsModel
    private let actions: SettingsActions
    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }

    init(model: SettingsModel, actions: SettingsActions) {
        self.model = model
        self.actions = actions
    }

    func show(_ section: SettingsSection? = nil) {
        if let section { model.selection = section }
        model.diagnosticsCopied = false
        model.starterFileError = nil
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: SettingsView(model: model, actions: actions)))
            window.title = "Tafl Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 780, height: 540))
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

private struct SettingsView: View {
    @Bindable var model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $model.selection) { section in
                Label(section.title, systemImage: section.symbol).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            detail.navigationTitle(model.selection.title)
        }
        .frame(minWidth: 680, minHeight: 440)
    }

    @ViewBuilder private var detail: some View {
        switch model.selection {
        case .overview: OverviewSection(model: model, actions: actions)
        case .shortcuts: ShortcutsSection(model: model)
        case .layouts: LayoutsSection(model: model, actions: actions)
        case .displays: DisplaysSection(model: model)
        case .tiling: TilingSection(model: model, actions: actions)
        case .permissions: PermissionsSection(model: model, actions: actions)
        case .about: AboutSection(model: model, actions: actions)
        }
    }
}
