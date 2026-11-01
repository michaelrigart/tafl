import os

enum Log {
    static let app = Logger(subsystem: "com.michaelrigart.tafl", category: "app")
    static let engine = Logger(subsystem: "com.michaelrigart.tafl", category: "engine")
    static let config = Logger(subsystem: "com.michaelrigart.tafl", category: "config")
    static let ui = Logger(subsystem: "com.michaelrigart.tafl", category: "ui")
}
