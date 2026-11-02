import Foundation

public struct WindowHandle: Hashable, Codable, Sendable {
    public var pid: Int32
    public var windowID: UInt32
    /// False for a synthetic id, used when neither the private symbol nor the window list
    /// resolves one. Unstable handles are never persisted.
    public var isStable: Bool

    public init(pid: Int32, windowID: UInt32, isStable: Bool) {
        self.pid = pid
        self.windowID = windowID
        self.isStable = isStable
    }
}

public struct WindowSnapshot: Equatable, Sendable {
    public var handle: WindowHandle
    public var bundleID: String?
    public var appName: String
    public var title: String
    public var frame: ScreenRect
    public var canMove: Bool
    public var canResize: Bool
    public var minSize: ScreenSize?
    public var isFullscreen: Bool
    public var isSheet: Bool
    public var isMinimized: Bool
    public var isAppHidden: Bool

    public init(
        handle: WindowHandle,
        bundleID: String?,
        appName: String,
        title: String,
        frame: ScreenRect,
        canMove: Bool,
        canResize: Bool,
        minSize: ScreenSize?,
        isFullscreen: Bool,
        isSheet: Bool,
        isMinimized: Bool,
        isAppHidden: Bool
    ) {
        self.handle = handle
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.frame = frame
        self.canMove = canMove
        self.canResize = canResize
        self.minSize = minSize
        self.isFullscreen = isFullscreen
        self.isSheet = isSheet
        self.isMinimized = isMinimized
        self.isAppHidden = isAppHidden
    }
}

extension WindowSnapshot {
    /// Whether Tafl may place the window: not full screen, minimized, in a hidden app or a sheet.
    public var isPlaceable: Bool {
        !isFullscreen && !isMinimized && !isAppHidden && !isSheet
    }
}
