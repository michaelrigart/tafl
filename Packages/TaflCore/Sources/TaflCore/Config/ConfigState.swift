import Foundation

public enum ConfigRead: Sendable {
    case missing
    case text(String)
    case unreadable(String)
}

public enum ConfigStatus: Equatable, Sendable {
    case defaults
    case loaded
    case rejected(ConfigError)
}

/// Keeps the last good configuration when a read fails to parse or validate.
public struct ConfigState: Sendable {
    public private(set) var effective: Config
    public private(set) var status: ConfigStatus

    public init() {
        effective = .defaults
        status = .defaults
    }

    public mutating func apply(_ read: ConfigRead, table: KeyboardLayoutTable) {
        switch read {
        case .missing:
            effective = .defaults
            status = .defaults
        case .text(let text):
            switch ConfigParser.parse(text, table: table) {
            case .success(let config):
                effective = config
                status = .loaded
            case .failure(let error):
                status = .rejected(error)
            }
        case .unreadable(let reason):
            status = .rejected(ConfigError(line: nil, message: reason))
        }
    }
}
