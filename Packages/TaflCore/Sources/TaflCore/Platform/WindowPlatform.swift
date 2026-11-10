import Foundation

public enum PlatformFailure: Error, Equatable, Sendable {
    case noWindow, notResponding, cannotMove, fullscreen
}

public struct TilingSettings: Equatable, Sendable {
    /// Every setting is nil when its key is unset (macOS applies its own default).
    public var edgeDrag: Bool?
    public var optionAccelerator: Bool?
    public var topEdgeDrag: Bool?
    public var tiledMargins: Bool?

    public init(edgeDrag: Bool?, optionAccelerator: Bool?, topEdgeDrag: Bool?, tiledMargins: Bool?) {
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
///
/// A write asks `admit` in the same serial work for the window's app that makes the write,
/// immediately before it, so every read of the app queued ahead of the write has reached its
/// `take` first. The write is made only when `admit` answers `.write`; the result is its answer.
/// A failure means the write was admitted, and may or may not have happened.
public protocol WriteSession: Sendable {
    /// Reads the frame and hands it to `take` inside the read (see `WindowPlatform`). The result is
    /// what `take` returned.
    func readFrame<T: Sendable>(take: @escaping @Sendable (ScreenRect) -> T) async -> Result<T, PlatformFailure>
    func setSize(_ size: ScreenSize, admit: @escaping @Sendable () -> WriteGo) async -> Result<WriteGo, PlatformFailure>
    func setPosition(_ point: ScreenPoint, admit: @escaping @Sendable () -> WriteGo) async -> Result<WriteGo, PlatformFailure>
    func end() async
}

/// An app whose window events macOS would not deliver, found when observing started.
public struct UnobservableApp: Equatable, Sendable {
    public var pid: Int32
    public var bundleID: String?
    public var missing: Set<ObservedEvent>

    public init(pid: Int32, bundleID: String?, missing: Set<ObservedEvent>) {
        self.pid = pid
        self.bundleID = bundleID
        self.missing = missing
    }
}

/// Every read of a window hands what it read to the caller's `take` inside the read: in the same
/// serial work for the window's app that made the read, before any later read of that app's windows
/// begins. So a `take` sees one window's readings in the order they were read. Its result is the
/// read's result. `take` must be quick and must not call back into the platform.
public protocol WindowPlatform: Sendable {
    func displays() async -> [Display]
    func focusedWindow<T: Sendable>(take: @escaping @Sendable (WindowSnapshot) -> T) async -> Result<T, PlatformFailure>
    /// Running apps, every display's current Space.
    func visibleWindows<T: Sendable>(take: @escaping @Sendable (WindowSnapshot) -> T) async -> [T]
    func snapshot<T: Sendable>(
        of handle: WindowHandle,
        take: @escaping @Sendable (WindowSnapshot) -> T
    ) async -> Result<T, PlatformFailure>
    /// The name of the running app with this process id, answered without asking the app, so it
    /// works for one that does not respond.
    func appName(pid: Int32) async -> String?
    /// When each of these processes was launched, answered without asking the apps. A pid
    /// missing from the answer is not running, or has no launch date.
    func launchDates(of pids: Set<Int32>) async -> [Int32: Date]
    /// Waits while another session for the same app is open. Every successful call must be
    /// ended with `end()`: until it is, the app's next session waits and its Enhanced UI stays off.
    func beginWriting(_ handle: WindowHandle) async -> Result<any WriteSession, PlatformFailure>
    func pointerDisplay() async -> DisplayIdentity?
    func tilingSettings() async -> TilingSettings
    func isAccessibilityGranted() async -> Bool
    func capabilities() async -> [CapabilityState]
    var events: AsyncStream<PlatformEvent> { get }
    /// Starts observing every running app, telling `notices` of each window's announcement and end,
    /// and of each app's quit, in the app's order. The apps whose events could not be observed are
    /// the result; one that fails later arrives as a `.unobservable` event.
    func startObserving(notices: any WindowNotices) async -> [UnobservableApp]
    /// Stops observing. `events` stays open: the engine keeps consuming it across a restart.
    func stopObserving() async
}

extension WindowPlatform {
    /// The displays a window is placed on or navigated between: `displays()` without a placeholder
    /// (see `Display.isPlaceholder`), which is no real display. Only the settle logic reads
    /// `displays()` itself, to see a placeholder and wait it out.
    public func usableDisplays() async -> [Display] {
        await displays().filter { !$0.isPlaceholder }
    }
}
