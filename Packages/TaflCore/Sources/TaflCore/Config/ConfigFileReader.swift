import Foundation

public enum ConfigFileReader {
    /// A link to a file that is gone is unreadable, not missing: the file is there to be fixed.
    public static func read(path: String) -> ConfigRead {
        let manager = FileManager.default
        guard manager.fileExists(atPath: path) else {
            if (try? manager.destinationOfSymbolicLink(atPath: path)) != nil {
                return .unreadable("config.toml points to a missing file")
            }
            return .missing
        }
        guard let data = manager.contents(atPath: path) else { return .unreadable("config.toml can't be read") }
        guard let text = String(data: data, encoding: .utf8) else {
            return .unreadable("config.toml isn't valid UTF-8 text")
        }
        return .text(text)
    }
}
