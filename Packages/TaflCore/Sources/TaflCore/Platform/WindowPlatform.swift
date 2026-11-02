import Foundation

public enum PlatformFailure: Error, Equatable, Sendable {
    case noWindow, notResponding, cannotMove, fullscreen
}

public struct TilingSettings: Equatable, Sendable {
    public var edgeDrag: Bool
    public var optionAccelerator: Bool
    public var topEdgeDrag: Bool
    /// Nil when the setting is unset.
    public var tiledMargins: Bool?

    public init(edgeDrag: Bool, optionAccelerator: Bool, topEdgeDrag: Bool, tiledMargins: Bool?) {
        self.edgeDrag = edgeDrag
        self.optionAccelerator = optionAccelerator
        self.topEdgeDrag = topEdgeDrag
        self.tiledMargins = tiledMargins
    }
}

public struct CapabilityState: Equatable, Sendable {
    public var name: String
    public var isAvailable: Bool
    /// Fixed text.
    public var note: String

    public init(name: String, isAvailable: Bool, note: String) {
        self.name = name
        self.isAvailable = isAvailable
        self.note = note
    }
}

/// A run of writes to one window. The platform switches Enhanced UI off when the session
/// begins and restores it at `end()`. Enhanced UI is per app, so at most one session per app
/// exists at a time, whoever asked for it.
public protocol WriteSession: Sendable {
    func readFrame() async -> Result<ScreenRect, PlatformFailure>
    func setSize(_ size: ScreenSize) async -> Result<Void, PlatformFailure>
    func setPosition(_ point: ScreenPoint) async -> Result<Void, PlatformFailure>
    func end() async
}

public protocol WindowPlatform: Sendable {
    func displays() async -> [Display]
    func focusedWindow() async -> Result<WindowSnapshot, PlatformFailure>
    /// Running apps, every display's current Space.
    func visibleWindows() async -> [WindowSnapshot]
    func snapshot(of handle: WindowHandle) async -> Result<WindowSnapshot, PlatformFailure>
    /// The name of the running app with this process id, answered without asking the app, so it
    /// works for one that does not respond.
    func appName(pid: Int32) async -> String?
    /// Waits while another session for the same app is open.
    func beginWriting(_ handle: WindowHandle) async -> Result<any WriteSession, PlatformFailure>
    func pointerDisplay() async -> DisplayIdentity?
    func tilingSettings() async -> TilingSettings
    func isAccessibilityGranted() async -> Bool
    func capabilities() async -> [CapabilityState]
    var events: AsyncStream<PlatformEvent> { get }
    func startObserving() async
    func stopObserving() async
}
