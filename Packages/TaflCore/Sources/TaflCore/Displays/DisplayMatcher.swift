import Foundation

public enum DisplayMatcher {
    public static func display(for reference: String, in displays: [Display]) -> Display? {
        let named = displays.filter { $0.identity.name == reference }
        if named.count == 1 { return named[0] }
        return displays.first { $0.identity.identifier == reference }
    }

    /// What to write in the config to name `display`: its name, or its identifier where another
    /// connected display shares the name.
    public static func reference(for display: Display, among displays: [Display]) -> String {
        let repeated = displays.filter { $0.identity.name == display.identity.name }.count > 1
        return repeated ? display.identity.identifier : display.identity.name
    }

    public static func claims(_ references: [String], _ displays: [Display]) -> Bool {
        guard references.count == displays.count else { return false }
        var matched: [DisplayIdentity] = []
        for reference in references {
            guard let found = display(for: reference, in: displays) else { return false }
            matched.append(found.identity)
        }
        return Set(matched).count == displays.count
    }
}
