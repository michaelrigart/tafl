import Foundation

public struct ConfigError: Error, Equatable, Sendable, CustomStringConvertible {
    public let line: Int?
    public let message: String

    public init(line: Int?, message: String) {
        self.line = line
        self.message = message
    }

    public var description: String {
        guard let line else { return message }
        return "Line \(line): \(message)"
    }

    /// Reads TOMLDecoder's text, whose "(Line N) " prefix moves into `line`.
    init(tomlDescription description: String) {
        let prefix = "(Line "
        if description.hasPrefix(prefix),
           let close = description.firstIndex(of: ")"),
           let line = Int(description[description.index(description.startIndex, offsetBy: prefix.count)..<close]) {
            var rest = description[description.index(after: close)...]
            if rest.first == " " { rest = rest.dropFirst() }
            self.init(line: line, message: String(rest))
        } else {
            self.init(line: nil, message: description)
        }
    }
}
