import Foundation

public enum RepeatMode: String, Sendable {
    case displays, sizes, none
}

public enum ShortcutBinding: Equatable, Sendable {
    case standard
    case custom(Shortcut)
    case unbound
}

public struct LayoutEntry: Equatable, Sendable {
    public let app: String
    public let title: String?
    public let place: NamedPlacement
    public let display: String?

    public init(app: String, title: String?, place: NamedPlacement, display: String?) {
        self.app = app
        self.title = title
        self.place = place
        self.display = display
    }
}

public struct LayoutDefinition: Equatable, Sendable {
    public let name: String
    public let displays: [String]
    public let shortcut: Shortcut?
    public let entries: [LayoutEntry]

    public init(name: String, displays: [String], shortcut: Shortcut?, entries: [LayoutEntry]) {
        self.name = name
        self.displays = displays
        self.shortcut = shortcut
        self.entries = entries
    }
}

public struct Config: Equatable, Sendable {
    /// An action that is absent is on its standard shortcut.
    public let shortcuts: [Action: ShortcutBinding]
    public let repeatMode: RepeatMode
    public let gap: Double
    public let step: Double
    public let menuBarIcon: Bool
    public let launchAtLogin: Bool
    public let layouts: [LayoutDefinition]

    public init(
        shortcuts: [Action: ShortcutBinding],
        repeatMode: RepeatMode,
        gap: Double,
        step: Double,
        menuBarIcon: Bool,
        launchAtLogin: Bool,
        layouts: [LayoutDefinition]
    ) {
        self.shortcuts = shortcuts
        self.repeatMode = repeatMode
        self.gap = gap
        self.step = step
        self.menuBarIcon = menuBarIcon
        self.launchAtLogin = launchAtLogin
        self.layouts = layouts
    }

    public static let defaults = Config(
        shortcuts: [:],
        repeatMode: .displays,
        gap: 0,
        step: 30,
        menuBarIcon: true,
        launchAtLogin: true,
        layouts: []
    )

    public func binding(for action: Action) -> ShortcutBinding {
        shortcuts[action] ?? .standard
    }
}
