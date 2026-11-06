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
    var windowID: ResolvedWindowID?
}

enum Windows27 {
    /// Whether an element is a standard window or a sheet, from two Accessibility calls: a cheap
    /// test before a full read of an element that may not be a window at all.
    static func isTrackedElement(_ element: AXUIElement) -> Bool {
        isTracked(role: AXWindowAccess.role(element), subrole: AXWindowAccess.subrole(element))
    }

    /// Blocks on Accessibility: call it only on the app's `AXQueue`.
    static func read(_ element: AXUIElement, pid: pid_t, resolveID: Bool) -> Result<ElementRead, AXFailure> {
        attributes(of: element, asking: .live).map { attributes in
            let id = resolveID
                ? WindowIDResolver.windowID(element, pid: pid, frame: attributes.frame).map { ResolvedWindowID(id: $0.0, by: $0.1) }
                : nil
            return ElementRead(element: AXElementBox(element), attributes: attributes, windowID: id)
        }
    }

    /// A window's frame is the one attribute it must give. Any other it lacks takes its default (no
    /// role, no title, not settable, no minimum size, not full screen, not minimized), but a query
    /// the app did not answer, or one that found the window gone, fails the read as a frame query
    /// would, at the first: a timeout is never a "no". The role and subrole are read once, and the
    /// window element is resolved once for the full-screen and minimized tests.
    static func attributes<Element>(
        of element: Element,
        asking ask: WindowQueries27<Element>
    ) -> Result<WindowAttributes27, AXFailure> {
        Result { () throws(AXFailure) -> WindowAttributes27 in
            let frame = try ask.frame(element).get()
            let role = try ask.string(element, kAXRoleAttribute).answer()
            let subrole = try ask.string(element, kAXSubroleAttribute).answer()
            let window = try ask.windowElement(of: element, role: role, subrole: { subrole })
            let title = try ask.string(element, kAXTitleAttribute).answer() ?? ""
            let canMove = try ask.settable(element, kAXPositionAttribute).answer() ?? false
            let canResize = try ask.settable(element, kAXSizeAttribute).answer() ?? false
            var minSize = try ask.size(element, "AXMinSize").answer()
            if minSize == nil { minSize = try ask.size(element, "AXMinimumSize").answer() }
            let isFullscreen = try ask.isFullscreen(element, window: window)
            var isMinimized = false
            if let window { isMinimized = try ask.bool(window, kAXMinimizedAttribute).answer() ?? false }
            return WindowAttributes27(
                role: role, subrole: subrole, title: title, frame: frame, canMove: canMove, canResize: canResize,
                minSize: minSize, isFullscreen: isFullscreen, isMinimized: isMinimized)
        }
    }

    static func isSheet(_ attributes: WindowAttributes27) -> Bool {
        attributes.role == kAXSheetRole || attributes.subrole == kAXSheetRole
    }

    /// Standard windows and sheets; dialogs, palettes and the rest are left out of enumeration and events.
    static func isTracked(_ attributes: WindowAttributes27) -> Bool {
        isTracked(role: attributes.role, subrole: attributes.subrole)
    }

    private static func isTracked(role: String?, subrole: String?) -> Bool {
        subrole == kAXStandardWindowSubrole || role == kAXSheetRole || subrole == kAXSheetRole
    }

    /// The snapshot of any window element, as the focused path and `snapshot(of:)` need it. A system
    /// dialog is never resizable, as in Rectangle.
    static func snapshot(handle: WindowHandle, app: AppInfo27, attributes: WindowAttributes27) -> WindowSnapshot {
        WindowSnapshot(
            handle: handle,
            bundleID: app.bundleID,
            appName: app.name,
            title: attributes.title,
            frame: screenRect(attributes.frame),
            canMove: attributes.canMove,
            canResize: attributes.canResize && attributes.subrole != kAXSystemDialogSubrole,
            minSize: attributes.minSize.map { ScreenSize(width: $0.width, height: $0.height) },
            isFullscreen: attributes.isFullscreen,
            isSheet: isSheet(attributes),
            isMinimized: attributes.isMinimized,
            isAppHidden: app.isHidden)
    }

    /// The snapshot of a standard window or sheet, nil for anything else.
    static func trackedSnapshot(handle: WindowHandle, app: AppInfo27, attributes: WindowAttributes27) -> WindowSnapshot? {
        isTracked(attributes) ? snapshot(handle: handle, app: app, attributes: attributes) : nil
    }

    static func screenRect(_ rect: CGRect) -> ScreenRect {
        ScreenRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    /// A timeout from the messaging limit arrives as `kAXErrorCannotComplete`, like an app that cannot answer.
    static func failure(for code: AXError) -> PlatformFailure {
        code == .cannotComplete ? .notResponding : .noWindow
    }

    /// Settable, then write, each classified by its own error code: a timeout is `.notResponding`,
    /// never "can't move"; only a genuine refusal is `.fullscreen` or `.cannotMove`.
    static func writePosition(
        settable: () -> Result<Bool, AXFailure>,
        write: () -> AXError,
        isFullscreen: () -> Result<Bool, AXFailure>
    ) -> Result<Void, PlatformFailure> {
        switch settable() {
        case .failure(let failure):
            return .failure(positionFailure(for: failure.code, isFullscreen: isFullscreen))
        case .success(false):
            return .failure(positionFailure(for: .failure, isFullscreen: isFullscreen))
        case .success(true):
            break
        }
        let code = write()
        return code == .success ? .success(()) : .failure(positionFailure(for: code, isFullscreen: isFullscreen))
    }

    /// A refusal says why by asking whether the window is full screen; an app that does not answer
    /// that is `.notResponding`, and a window gone by then is `.noWindow`.
    static func positionFailure(for code: AXError, isFullscreen: () -> Result<Bool, AXFailure>) -> PlatformFailure {
        switch code {
        case .cannotComplete: return .notResponding
        case .invalidUIElement: return .noWindow
        default:
            switch isFullscreen() {
            case .success(let fullscreen): return fullscreen ? .fullscreen : .cannotMove
            case .failure(let unanswered): return positionFailure(for: unanswered.code, isFullscreen: { .success(false) })
            }
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
