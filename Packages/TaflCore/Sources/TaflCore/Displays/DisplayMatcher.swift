import Foundation

public enum DisplayMatcher {
    public static func display(for reference: String, in displays: [Display]) -> Display? {
        let named = displays.filter { $0.identity.name == reference }
        if named.count == 1 { return named[0] }
        return displays.first { $0.identity.identifier == reference }
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
