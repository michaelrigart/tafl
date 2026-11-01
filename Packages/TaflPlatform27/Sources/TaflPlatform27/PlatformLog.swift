import os

public enum PlatformLog {
    public static let probe = Logger(subsystem: "com.michaelrigart.tafl", category: "probe")
    public static let windows = Logger(subsystem: "com.michaelrigart.tafl", category: "windows")
    public static let displays = Logger(subsystem: "com.michaelrigart.tafl", category: "displays")
    public static let keys = Logger(subsystem: "com.michaelrigart.tafl", category: "keys")
}
