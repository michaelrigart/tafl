import Foundation

/// Builds a `[[layouts]]` snippet from the windows on the current Space, for the user to paste
/// into the config file.
public enum CaptureBuilder {
    public static func snippet(windows: [WindowSnapshot], displays: [Display], gap: Double) -> String {
        guard !displays.isEmpty else { return "# No displays are connected.\n" }
        let references = displays.map { DisplayMatcher.reference(for: $0, among: displays) }
        let captured = ordered(windows.filter(\.isPlaceable), displays: displays, gap: gap)

        var entries: [Entry] = []
        var unplaced: [String] = []
        for item in captured {
            guard let app = item.window.bundleID else {
                unplaced.append("an app without a bundle identifier: no recognised placement")
                continue
            }
            guard let place = item.place else {
                unplaced.append("\(app): no recognised placement")
                continue
            }
            let needsTitle = !isUniform(app, in: captured)
            let entry = Entry(
                app: app,
                title: needsTitle ? TitleGlob.escape(item.window.title) : nil,
                place: place,
                display: displays.count > 1 ? references[item.displayIndex] : nil)
            if let shadow = entries.first(where: { shadows($0, window: item.window) }) {
                // The same entry again is nothing new; a different placement can never be reached,
                // because the earlier entry matches this window first.
                if shadow.place != entry.place || shadow.display != entry.display { unplaced.append("\(app): same title as another window, can't be told apart") }
                continue
            }
            if !entries.contains(entry) { entries.append(entry) }
        }

        var lines = [
            "[[layouts]]",
            "name = \"Captured\"",
            "displays = [\(references.map(TOMLString.quoted).joined(separator: ", "))]",
        ]
        for entry in entries {
            lines.append("")
            lines.append("  [[layouts.windows]]")
            lines.append("  app = \(TOMLString.quoted(entry.app))")
            if let title = entry.title { lines.append("  title = \(TOMLString.quoted(title))") }
            lines.append("  place = \(TOMLString.quoted(entry.place.rawValue))")
            if let display = entry.display { lines.append("  display = \(TOMLString.quoted(display))") }
        }
        if !unplaced.isEmpty {
            lines.append("")
            lines.append(contentsOf: unplaced.map { "# \(commentSafe($0))" })
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private struct Entry: Equatable {
        var app: String
        var title: String?
        var place: NamedPlacement
        var display: String?
    }

    /// Whether `entry`, which comes first, also matches `window`.
    private static func shadows(_ entry: Entry, window: WindowSnapshot) -> Bool {
        guard let title = entry.title, entry.app == window.bundleID else { return false }
        return TitleGlob.matches(title, window.title)
    }

    private struct Captured {
        var window: WindowSnapshot
        var displayIndex: Int
        var place: NamedPlacement?
    }

    /// Windows in a stable order: display, then top to bottom, then left to right.
    private static func ordered(_ windows: [WindowSnapshot], displays: [Display], gap: Double) -> [Captured] {
        windows.compactMap { window -> Captured? in
            guard let display = DisplayLocator.display(containing: window.frame, in: displays),
                  let index = displays.firstIndex(of: display)
            else { return nil }
            return Captured(
                window: window, displayIndex: index,
                place: PlacementRecognizer.recognize(window.frame, on: display, gap: gap))
        }
        .sorted {
            ($0.displayIndex, $0.window.frame.y, $0.window.frame.x)
                < ($1.displayIndex, $1.window.frame.y, $1.window.frame.x)
        }
    }

    /// An app whose windows are all in one placement on one display needs no title to tell them apart.
    private static func isUniform(_ app: String, in captured: [Captured]) -> Bool {
        let own = captured.filter { $0.window.bundleID == app }
        guard let first = own.first, first.place != nil else { return false }
        return own.allSatisfy { $0.place == first.place && $0.displayIndex == first.displayIndex }
    }

    /// A comment ends at the line's end, so a line break in a bundle identifier must not escape it.
    private static func commentSafe(_ text: String) -> String {
        String(text.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F })
    }
}
