import Observation
import TaflCore

enum SettingsSection: String, CaseIterable, Identifiable {
    case overview, shortcuts, layouts, displays, tiling, permissions, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .shortcuts: "Shortcuts"
        case .layouts: "Layouts"
        case .displays: "Displays"
        case .tiling: "macOS tiling"
        case .permissions: "Permissions"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "doc.text"
        case .shortcuts: "keyboard"
        case .layouts: "rectangle.3.group"
        case .displays: "display"
        case .tiling: "rectangle.split.2x1"
        case .permissions: "lock.shield"
        case .about: "info.circle"
        }
    }
}

/// What the Settings window shows. The composition root feeds it from the controllers; the views
/// only read it, because Settings never edits the configuration.
@MainActor
@Observable
final class SettingsModel {
    var selection: SettingsSection = .overview

    var configPath = ""
    var fileExists = false
    var status: ConfigStatus = .defaults
    var config: Config = .defaults
    var activationFailures: [HotkeyTarget: ActivationFailure] = [:]
    var activeLayout: String?
    var table = KeyboardLayoutTable([:])
    var trusted = false
    var recentFailures: [String] = []

    var displays: [Display] = []
    var tiling: TilingSettings?
    var capabilities: [CapabilityState] = []

    var starterFileError: String?
    var capturedSnippet: String?
    var captureNote: String?
    var diagnosticsCopied = false

    /// The shortcut as the file writes it, in the current layout's characters.
    func shortcutText(for action: Action) -> String {
        switch config.binding(for: action) {
        case .unbound:
            return "none"
        case .custom(let shortcut):
            return shortcut.text
        case .standard:
            guard let chord = DefaultShortcuts.chords[action],
                  let shortcut = KeyTranslator.shortcut(for: chord, table: table)
            else { return "default key" }
            return shortcut.text
        }
    }
}

extension ActivationFailure {
    var settingsText: String {
        switch self {
        case .untranslatable(let message): message
        case .taken: "Not registered: another app holds this shortcut"
        case .clashes: "Not registered: it shares its keys with another shortcut"
        }
    }
}
