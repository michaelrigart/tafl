public struct ActiveLayout: Equatable, Sendable {
    public private(set) var name: String?

    public init(name: String? = nil) {
        self.name = name
    }

    /// Only a layout the config has can become active; asked for one it lacks, nothing changes and
    /// the answer is false.
    @discardableResult
    public mutating func activate(_ name: String, in config: Config) -> Bool {
        guard config.layouts.contains(where: { $0.name == name }) else { return false }
        self.name = name
        return true
    }

    public mutating func endForDisplayChange() {
        name = nil
    }

    public mutating func reconcile(with config: Config) {
        if definition(in: config) == nil { name = nil }
    }

    public func definition(in config: Config) -> LayoutDefinition? {
        guard let name else { return nil }
        return config.layouts.first { $0.name == name }
    }
}
