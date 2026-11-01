import os

public enum PlatformLog {
    static let probe = Logger(subsystem: "com.michaelrigart.tafl", category: "probe")
    static let windows = Logger(subsystem: "com.michaelrigart.tafl", category: "windows")
    static let displays = Logger(subsystem: "com.michaelrigart.tafl", category: "displays")
    static let keys = Logger(subsystem: "com.michaelrigart.tafl", category: "keys")
}
