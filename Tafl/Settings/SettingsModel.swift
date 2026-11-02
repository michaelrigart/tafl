import Combine
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
/// only read it, because Settings never edits the configuration. It is an `ObservableObject`
/// because `@Observable` expands to `Observation.…`, which `TaflCore.Observation` shadows in any
/// file that imports TaflCore.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var selection: SettingsSection = .overview

    @Published var configPath = ""
    @Published var fileExists = false
    @Published var status: ConfigStatus = .defaults
    @Published var config: Config = .defaults
    @Published var activationFailures: [HotkeyTarget: ActivationFailure] = [:]
    @Published var activeLayout: String?
    @Published var table = KeyboardLayoutTable([:])
    @Published var trusted = false
    @Published var recentFailures: [String] = []

    @Published var displays: [Display] = []
    @Published var tiling: TilingSettings?
    @Published var capabilities: [CapabilityState] = []

    @Published var starterFileError: String?
    @Published var capturedSnippet: String?
    @Published var captureNote: String?
    @Published var diagnosticsCopied = false

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
