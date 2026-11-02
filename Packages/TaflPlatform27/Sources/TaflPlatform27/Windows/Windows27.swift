import ApplicationServices
import CoreGraphics
import TaflCore

/// What one window's element says about it, read on its app's `AXQueue`.
struct WindowAttributes27: Sendable, Equatable {
    var role: String?
    var subrole: String?
    var title: String
    var frame: CGRect
    var canMove: Bool
    var canResize: Bool
    var minSize: CGSize?
    var isFullscreen: Bool
    var isMinimized: Bool
}

struct ElementRead: Sendable {
    var element: AXElementBox
    var attributes: WindowAttributes27
    /// Resolved only when the read asked for it.
    var windowID: UInt32?
}

enum Windows27 {
    /// Blocks on Accessibility: call it only on the app's `AXQueue`. A window's frame is the one
    /// attribute it must read; a window that does not give one is a failure.
    static func read(_ element: AXUIElement, pid: pid_t, resolveID: Bool) -> Result<ElementRead, AXFailure> {
        switch AXWindowAccess.frame(element) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let frame):
            let attributes = WindowAttributes27(
                role: AXWindowAccess.role(element),
                subrole: AXWindowAccess.subrole(element),
                title: AXWindowAccess.title(element) ?? "",
                frame: frame,
                canMove: AXWindowAccess.isSettable(element, attribute: kAXPositionAttribute),
                canResize: AXWindowAccess.isSettable(element, attribute: kAXSizeAttribute),
                minSize: AXWindowAccess.minimumSize(element),
                isFullscreen: AXWindowAccess.isFullscreen(element) ?? AXWindowAccess.fullScreenAttribute(element) ?? false,
                isMinimized: AXWindowAccess.isMinimized(element) ?? false)
            let id = resolveID ? WindowIDResolver.windowID(element, pid: pid, frame: frame)?.0 : nil
            return .success(ElementRead(element: AXElementBox(element), attributes: attributes, windowID: id))
        }
    }

    static func isSheet(_ attributes: WindowAttributes27) -> Bool {
        attributes.role == kAXSheetRole || attributes.subrole == kAXSheetRole
    }

    /// Standard windows and sheets; dialogs, palettes and the rest are left out.
    static func isTracked(_ attributes: WindowAttributes27) -> Bool {
        attributes.subrole == kAXStandardWindowSubrole || isSheet(attributes)
    }

    static func snapshot(handle: WindowHandle, app: AppInfo27, attributes: WindowAttributes27) -> WindowSnapshot? {
        guard isTracked(attributes) else { return nil }
        return WindowSnapshot(
            handle: handle,
            bundleID: app.bundleID,
            appName: app.name,
            title: attributes.title,
            frame: screenRect(attributes.frame),
            canMove: attributes.canMove,
            canResize: attributes.canResize,
            minSize: attributes.minSize.map { ScreenSize(width: $0.width, height: $0.height) },
            isFullscreen: attributes.isFullscreen,
            isSheet: isSheet(attributes),
            isMinimized: attributes.isMinimized,
            isAppHidden: app.isHidden)
    }

    static func screenRect(_ rect: CGRect) -> ScreenRect {
        ScreenRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    /// A timeout from the messaging limit arrives as `kAXErrorCannotComplete`, like an app that cannot answer.
    static func failure(for code: AXError) -> PlatformFailure {
        code == .cannotComplete ? .notResponding : .noWindow
    }

    static func positionFailure(for code: AXError, isFullscreen: () -> Bool) -> PlatformFailure {
        switch code {
        case .cannotComplete: .notResponding
        case .invalidUIElement: .noWindow
        default: isFullscreen() ? .fullscreen : .cannotMove
        }
    }

    /// Nil for any other error: macOS may accept, clamp or ignore a size, and the core judges
    /// what it finds when it reads the frame back.
    static func sizeFailure(for code: AXError) -> PlatformFailure? {
        switch code {
        case .cannotComplete: .notResponding
        case .invalidUIElement: .noWindow
        default: nil
        }
    }
}
