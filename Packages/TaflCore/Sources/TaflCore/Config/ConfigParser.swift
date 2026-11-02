import Foundation
import TOMLDecoder

public enum ConfigParser {
    /// Parses and validates a config file. The first error in file order wins: the root's keys are
    /// walked in the order they appear, and `[shortcuts]` and `[[layouts]]` are checked where they stand.
    public static func parse(_ text: String, table: KeyboardLayoutTable) -> Result<Config, ConfigError> {
        var text = text
        if text.unicodeScalars.first == "\u{FEFF}" { text.unicodeScalars.removeFirst() }
        let root: TOMLTable
        do {
            root = try TOMLTable(source: text)
        } catch {
            return .failure(ConfigError(tomlDescription: error.description))
        }
        let walker = ConfigWalker(root: root, locator: SourceLocator(text), keyboard: table)
        do throws(ConfigError) {
            return .success(try walker.config())
        } catch {
            return .failure(error)
        }
    }
}

private typealias Path = [KeyPathComponent]

/// Who holds each chord. Defaults are claimed first and everything else as the walk reaches it in
/// file order, so a clash is always reported at the claim being added, the later one.
private struct Claims {
    private var owners: [KeyChord: String] = [:]

    mutating func addDefault(_ chord: KeyChord, owner: String) {
        owners[chord] = owner
    }

    mutating func add(_ chord: KeyChord, owner: String, text: String, line: Int?) throws(ConfigError) {
        if let existing = owners[chord] {
            throw ConfigError(line: line, message: "\"\(text)\" is also used by \(existing)")
        }
        owners[chord] = owner
    }
}

private struct ConfigWalker {
    let root: TOMLTable
    let locator: SourceLocator
    let keyboard: KeyboardLayoutTable

    func config() throws(ConfigError) -> Config {
        var repeatMode = Config.defaults.repeatMode
        var gap = Config.defaults.gap
        var step = Config.defaults.step
        var menuBarIcon = Config.defaults.menuBarIcon
        var launchAtLogin = Config.defaults.launchAtLogin

        var shortcuts: [Action: ShortcutBinding] = [:]
        var layouts: [LayoutDefinition] = []
        var claims = Claims()
        // An action named in [shortcuts], even wrongly, no longer holds its default chord.
        let moved = Set((try? root.table(forKey: "shortcuts"))?.keys ?? [])
        for action in Action.allCases where !moved.contains(action.rawValue) {
            if let chord = DefaultShortcuts.chords[action] { claims.addDefault(chord, owner: action.rawValue) }
        }

        for key in orderedKeys(root, at: []) {
            let path: Path = [.key(key)]
            switch key {
            case "repeat":
                let value = try string(root, key, path)
                guard let mode = RepeatMode(rawValue: value) else {
                    throw fail(path, "repeat must be \"displays\", \"sizes\" or \"none\"")
                }
                repeatMode = mode
            case "gap":
                gap = try number(root, key, path)
                guard (0...100).contains(gap) else { throw fail(path, "gap must be between 0 and 100") }
            case "step":
                step = try number(root, key, path)
                guard (1...500).contains(step) else { throw fail(path, "step must be between 1 and 500") }
            case "menu-bar-icon":
                menuBarIcon = try bool(root, key, path)
            case "launch-at-login":
                launchAtLogin = try bool(root, key, path)
            case "shortcuts":
                shortcuts = try shortcutBindings(&claims)
            case "layouts":
                layouts = try layoutDefinitions(&claims)
            default:
                throw fail(path, "unknown key \"\(key)\"")
            }
        }

        return Config(
            shortcuts: shortcuts,
            repeatMode: repeatMode,
            gap: gap,
            step: step,
            menuBarIcon: menuBarIcon,
            launchAtLogin: launchAtLogin,
            layouts: layouts
        )
    }

    // MARK: Shortcuts

    private func shortcutBindings(_ claims: inout Claims) throws(ConfigError) -> [Action: ShortcutBinding] {
        let sectionPath: Path = [.key("shortcuts")]
        var bindings: [Action: ShortcutBinding] = [:]
        let section = try subtable(root, "shortcuts", sectionPath, expected: "a table")
        for key in orderedKeys(section, at: sectionPath) {
            let path = sectionPath + [.key(key)]
            guard let action = Action(rawValue: key) else { throw fail(path, "unknown action \"\(key)\"") }
            let text = try string(section, key, path)
            if isNone(text) {
                bindings[action] = .unbound
                continue
            }
            let shortcut = try shortcut(text, path)
            try claims.add(try chord(shortcut, path), owner: action.rawValue, text: shortcut.text, line: line(path))
            bindings[action] = .custom(shortcut)
        }
        return bindings
    }

    private func isNone(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).lowercased() == "none"
    }

    private func shortcut(_ text: String, _ path: Path) throws(ConfigError) -> Shortcut {
        switch Shortcut.parse(text) {
        case .success(let shortcut): return shortcut
        case .failure(let error): throw fail(path, error.message)
        }
    }

    private func chord(_ shortcut: Shortcut, _ path: Path) throws(ConfigError) -> KeyChord {
        switch KeyTranslator.chord(for: shortcut, table: keyboard) {
        case .success(let chord): return chord
        case .failure(let error): throw fail(path, error.message)
        }
    }

    // MARK: Layouts

    private func layoutDefinitions(_ claims: inout Claims) throws(ConfigError) -> [LayoutDefinition] {
        let listPath: Path = [.key("layouts")]
        let list = try array(root, "layouts", listPath, expected: "a list of tables")
        var layouts: [LayoutDefinition] = []
        for index in 0..<list.count {
            let path = listPath + [.index(index)]
            let table = try element(list, index, path)
            layouts.append(try layout(table, path, earlier: layouts, &claims))
        }
        return layouts
    }

    private func layout(
        _ table: TOMLTable,
        _ path: Path,
        earlier: [LayoutDefinition],
        _ claims: inout Claims
    ) throws(ConfigError) -> LayoutDefinition {
        var name: String?
        var displays: [String]?
        var shortcut: Shortcut?
        var windows: TOMLArray?

        for key in orderedKeys(table, at: path) {
            let keyPath = path + [.key(key)]
            switch key {
            case "name":
                name = try string(table, key, keyPath)
            case "displays":
                let list = try stringList(table, key, keyPath)
                guard !list.isEmpty else { throw fail(keyPath, "displays must list at least one display") }
                displays = list
            case "shortcut":
                let text = try string(table, key, keyPath)
                if isNone(text) { throw fail(keyPath, "layout shortcut can't be \"none\"; leave it out instead") }
                shortcut = try self.shortcut(text, keyPath)
            case "windows":
                windows = try array(table, key, keyPath, expected: "a list of tables")
            default:
                throw fail(keyPath, "unknown key \"\(key)\"")
            }
        }

        guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw fail(path, "layout needs a name")
        }
        if earlier.contains(where: { $0.name == name }) {
            throw fail(path + [.key("name")], "layout name \"\(name)\" is used twice")
        }
        guard displays != nil || shortcut != nil else {
            throw fail(path, "layout \"\(name)\" needs displays or a shortcut")
        }
        if let displays, let other = earlier.first(where: { !$0.displays.isEmpty && Set($0.displays) == Set(displays) }) {
            throw fail(path + [.key("displays")], "layouts \"\(other.name)\" and \"\(name)\" both claim the same displays")
        }
        if let shortcut {
            let shortcutPath = path + [.key("shortcut")]
            try claims.add(
                try chord(shortcut, shortcutPath),
                owner: "layout \"\(name)\"",
                text: shortcut.text,
                line: line(shortcutPath)
            )
        }

        var entries: [LayoutEntry] = []
        if let windows {
            for index in 0..<windows.count {
                let entryPath = path + [.key("windows"), .index(index)]
                let entryTable = try element(windows, index, entryPath)
                entries.append(try entry(entryTable, entryPath, layoutName: name, displays: displays))
            }
        }
        return LayoutDefinition(name: name, displays: displays ?? [], shortcut: shortcut, entries: entries)
    }

    private func entry(
        _ table: TOMLTable,
        _ path: Path,
        layoutName: String,
        displays: [String]?
    ) throws(ConfigError) -> LayoutEntry {
        var app: String?
        var title: String?
        var place: NamedPlacement?
        var display: String?

        for key in orderedKeys(table, at: path) {
            let keyPath = path + [.key(key)]
            switch key {
            case "app":
                app = try string(table, key, keyPath)
            case "title":
                title = try string(table, key, keyPath)
            case "place":
                let value = try string(table, key, keyPath)
                guard let named = NamedPlacement(rawValue: value) else {
                    throw fail(keyPath, "unknown placement \"\(value)\"")
                }
                place = named
            case "display":
                display = try string(table, key, keyPath)
            default:
                throw fail(keyPath, "unknown key \"\(key)\"")
            }
        }

        guard let app else { throw fail(path, "each window entry needs an app") }
        guard let place else { throw fail(path, "each window entry needs a place") }
        if let displays {
            if let display {
                guard displays.contains(display) else {
                    throw fail(path + [.key("display")], "display \"\(display)\" isn't one of layout \"\(layoutName)\"'s displays")
                }
            } else if Set(displays).count > 1 {
                throw fail(path, "this entry needs a display, because layout \"\(layoutName)\" names more than one")
            }
        }
        return LayoutEntry(app: app, title: title, place: place, display: display)
    }

    // MARK: Lines

    /// The line of `path`, or of its nearest enclosing key when the path has none of its own.
    private func line(_ path: Path) -> Int? {
        var path = path
        while !path.isEmpty {
            if let line = locator.line(of: path) { return line }
            path.removeLast()
        }
        return nil
    }

    private func fail(_ path: Path, _ message: String) -> ConfigError {
        ConfigError(line: line(path), message: message)
    }

    /// TOMLTable lists value keys, then arrays, then tables; the file order comes from the locator.
    private func orderedKeys(_ table: TOMLTable, at path: Path) -> [String] {
        table.keys.enumerated()
            .sorted { lhs, rhs in
                let left = locator.line(of: path + [.key(lhs.element)]) ?? Int.max
                let right = locator.line(of: path + [.key(rhs.element)]) ?? Int.max
                return left != right ? left < right : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    // MARK: Typed access

    private func name(of path: Path) -> String {
        for component in path.reversed() {
            if case .key(let key) = component { return key }
        }
        return ""
    }

    private func wrongType(_ path: Path, _ expected: String) -> ConfigError {
        fail(path, "\"\(name(of: path))\" must be \(expected)")
    }

    /// TOMLDecoder checks a value only when it is read, so an invalid string such as a bad escape
    /// surfaces here; a type mismatch or a missing value means the key has the wrong type.
    private func readFailure(_ error: TOMLError, _ path: Path, _ expected: String) -> ConfigError {
        let description = error.description
        if description.contains("Type mismatch") || description.contains("not found in table") {
            return wrongType(path, expected)
        }
        let parsed = ConfigError(tomlDescription: description)
        return ConfigError(line: parsed.line ?? line(path), message: parsed.message)
    }

    private func string(_ table: TOMLTable, _ key: String, _ path: Path) throws(ConfigError) -> String {
        do {
            return try table.string(forKey: key)
        } catch {
            throw readFailure(error, path, "a string")
        }
    }

    private func bool(_ table: TOMLTable, _ key: String, _ path: Path) throws(ConfigError) -> Bool {
        guard let value = try? table.bool(forKey: key) else { throw wrongType(path, "true or false") }
        return value
    }

    private func number(_ table: TOMLTable, _ key: String, _ path: Path) throws(ConfigError) -> Double {
        if let value = try? table.integer(forKey: key) { return Double(value) }
        if let value = try? table.float(forKey: key) { return value }
        throw wrongType(path, "a number")
    }

    private func stringList(_ table: TOMLTable, _ key: String, _ path: Path) throws(ConfigError) -> [String] {
        guard let list = try? table.array(forKey: key) else { throw wrongType(path, "a list of strings") }
        var values: [String] = []
        for index in 0..<list.count {
            do {
                values.append(try list.string(atIndex: index))
            } catch {
                throw readFailure(error, path, "a list of strings")
            }
        }
        return values
    }

    private func subtable(_ table: TOMLTable, _ key: String, _ path: Path, expected: String) throws(ConfigError) -> TOMLTable {
        guard let value = try? table.table(forKey: key) else { throw wrongType(path, expected) }
        return value
    }

    private func array(_ table: TOMLTable, _ key: String, _ path: Path, expected: String) throws(ConfigError) -> TOMLArray {
        guard let value = try? table.array(forKey: key) else { throw wrongType(path, expected) }
        return value
    }

    private func element(_ list: TOMLArray, _ index: Int, _ path: Path) throws(ConfigError) -> TOMLTable {
        guard let value = try? list.table(atIndex: index) else { throw wrongType(path, "a list of tables") }
        return value
    }
}
