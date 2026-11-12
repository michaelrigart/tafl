import Foundation

public enum ConfigWatchTargets {
    private static let longestChain = 40

    /// The config file's directory, then the directory of every link target along the chain, in
    /// order and without duplicates. A relative target resolves against its link's directory.
    public static func directories(configPath: String, readLink: (String) -> String?) -> [String] {
        var directories = [directory(of: configPath)]
        var current = configPath
        var visited: Set<String> = [configPath]
        for _ in 0..<longestChain {
            guard let target = readLink(current) else { break }
            let resolved = resolve(target, against: directory(of: current))
            guard visited.insert(resolved).inserted else { break }
            let directory = directory(of: resolved)
            if !directories.contains(directory) { directories.append(directory) }
            current = resolved
        }
        return directories
    }

    private static func directory(of path: String) -> String {
        URL(fileURLWithPath: path).deletingLastPathComponent().path
    }

    private static func resolve(_ target: String, against directory: String) -> String {
        URL(fileURLWithPath: target, relativeTo: URL(fileURLWithPath: directory, isDirectory: true))
            .standardizedFileURL.path
    }
}
