import Foundation

/// What the menu says about a rejected config and about shortcuts that could not be registered.
public enum ConfigIssueLines {
    public static func lines(
        status: ConfigStatus, failures: [HotkeyTarget: ActivationFailure], layouts: [LayoutDefinition]
    ) -> [String] {
        var lines: [String] = []
        if case .rejected(let error) = status {
            lines.append("Config rejected, using the last good one. \(error)")
        }
        let order = failures.keys.sorted { rank($0, layouts) < rank($1, layouts) }
        for target in order {
            guard let failure = failures[target] else { continue }
            lines.append(line(target, failure))
        }
        return lines
    }

    private static func rank(_ target: HotkeyTarget, _ layouts: [LayoutDefinition]) -> Int {
        switch target {
        case .action(let action): Action.allCases.firstIndex(of: action) ?? Action.allCases.count
        case .layout(let name): Action.allCases.count + (layouts.firstIndex { $0.name == name } ?? layouts.count)
        }
    }

    private static func name(_ target: HotkeyTarget) -> String {
        switch target {
        case .action(let action): action.summary
        case .layout(let name): "Layout \(name)"
        }
    }

    private static func line(_ target: HotkeyTarget, _ failure: ActivationFailure) -> String {
        switch failure {
        case .untranslatable(let message): "\(name(target)): \(message)"
        case .taken: "\(name(target)): shortcut is taken by another app"
        case .clashes(let other): "\(name(target)): shortcut shares its keys with \(name(other))"
        }
    }
}
