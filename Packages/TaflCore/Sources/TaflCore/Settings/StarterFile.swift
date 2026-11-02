import Foundation

/// The file Create Starter File writes: every setting at its default, commented out.
public enum StarterFile {
    public static func text(table: KeyboardLayoutTable) -> String {
        let defaults = Config.defaults
        var lines = [
            "# Tafl configuration.",
            "#",
            "# Every setting is shown at its default, commented out. Remove the leading \"# \" from a",
            "# line to change it. Tafl never edits this file, and applies a saved change within a second.",
            "",
            "# How repeating a shortcut cycles: \"displays\", \"sizes\" or \"none\".",
            "# repeat = \"\(defaults.repeatMode.rawValue)\"",
            "",
            "# Points between windows and to the display edges (0 to 100).",
            "# gap = \(number(defaults.gap))",
            "",
            "# Points that larger and smaller change a window by (1 to 500).",
            "# step = \(number(defaults.step))",
            "",
            "# Show the icon in the menu bar. Opening Tafl again opens Settings.",
            "# menu-bar-icon = \(defaults.menuBarIcon)",
            "",
            "# Start Tafl when you log in.",
            "# launch-at-login = \(defaults.launchAtLogin)",
            "",
            "# Shortcuts, written as the characters on your keyboard's keys. Use \"none\" to unbind an action.",
            "# [shortcuts]",
        ]
        for action in Action.allCases {
            guard let shortcut = defaultShortcut(for: action, table: table) else { continue }
            lines.append("# \(action.rawValue) = \"\(shortcut.text)\"")
        }
        lines.append("")
        lines.append("# An example layout. Layouts apply when exactly their displays are connected,")
        lines.append("# or from their shortcut. Find display names in Settings.")
        lines.append("# [[layouts]]")
        lines.append("# name = \"Desk\"")
        lines.append("# displays = [\"Studio Display\"]   # applies automatically when exactly these are connected")
        if let shortcut = exampleShortcut(table: table) {
            lines.append("# shortcut = \"\(shortcut.text)\"     # optional")
        }
        lines.append("#")
        lines.append("#   [[layouts.windows]]")
        lines.append("#   app = \"com.apple.Terminal\"")
        lines.append("#   place = \"first-third\"")
        lines.append("#")
        lines.append("#   [[layouts.windows]]")
        lines.append("#   app = \"com.apple.Safari\"")
        lines.append("#   title = \"*Docs*\"              # optional glob on the window title")
        lines.append("#   place = \"last-two-thirds\"")
        lines.append("#   display = \"Studio Display\"    # required when the layout names more than one display")
        return lines.joined(separator: "\n") + "\n"
    }

    /// The default for `action` as the characters the layout prints, or nil when the layout has no
    /// character for that key (the action still sits on its default key position).
    private static func defaultShortcut(for action: Action, table: KeyboardLayoutTable) -> Shortcut? {
        guard let chord = DefaultShortcuts.chords[action],
              let shortcut = KeyTranslator.shortcut(for: chord, table: table),
              Shortcut.parse(shortcut.text) == .success(shortcut),
              KeyTranslator.chord(for: shortcut, table: table) == .success(chord)
        else { return nil }
        return shortcut
    }

    /// Control, Option and Command on the key the spec's example calls "1".
    private static func exampleShortcut(table: KeyboardLayoutTable) -> Shortcut? {
        let chord = KeyChord(keyCode: 18, modifiers: [.control, .option, .command])
        guard let shortcut = KeyTranslator.shortcut(for: chord, table: table),
              Shortcut.parse(shortcut.text) == .success(shortcut),
              KeyTranslator.chord(for: shortcut, table: table) == .success(chord)
        else { return nil }
        return shortcut
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
