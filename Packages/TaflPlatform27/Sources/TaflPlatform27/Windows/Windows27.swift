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

    /// A window's frame is the one attribute it must give, and whether it can be moved and resized
    /// are the two whose failure changes the one Tafl reports. A query among them that the app did
    /// not answer, or that found the window gone, fails the read as a frame query would: a timeout
    /// is never a "can't move". They are asked first, so a read that fails asks nothing more. Every
    /// other attribute only refines the read, and takes its default however its query fails (no
    /// role, no title, no minimum size, not full screen, not minimized): an app that answers one
    /// with an immediate error still has its windows read, and a hung app has already failed. The
    /// role and subrole are read once, and the window element is resolved once for the full-screen
    /// and minimized tests.
    static func attributes<Element>(
        of element: Element,
        asking ask: WindowQueries27<Element>
    ) -> Result<WindowAttributes27, AXFailure> {
        Result { () throws(AXFailure) -> WindowAttributes27 in
            let frame = try ask.frame(element).get()
            let canMove = try ask.settable(element, kAXPositionAttribute).answer() ?? false
            let canResize = try ask.settable(element, kAXSizeAttribute).answer() ?? false
            // Asked through `takingDefaults`, none of these fails the read.
            let optional = ask.takingDefaults
            let role = try optional.string(element, kAXRoleAttribute).answer()
            let subrole = try optional.string(element, kAXSubroleAttribute).answer()
            let window = try optional.windowElement(of: element, role: role, subrole: { subrole })
            let title = try optional.string(element, kAXTitleAttribute).answer() ?? ""
            let minSize = try optional.minimumSize(of: element)
            let isFullscreen = try optional.isFullscreen(element, window: window)
            let isMinimized = try optional.isMinimized(window: window)
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

    /// Settable, then admission, then write, each classified by its own error code: a timeout is
    /// `.notResponding`, never "can't move"; only a genuine refusal is `.fullscreen` or `.cannotMove`.
    /// No call sits between the admission and the setter, and a write that cannot be made is never
    /// admitted. A write `admit` does not allow is not made, and its answer is the result.
    static func writePosition(
        settable: () -> Result<Bool, AXFailure>,
        admit: () -> WriteGo,
        write: () -> AXError,
        isFullscreen: () -> Result<Bool, AXFailure>
    ) -> Result<WriteGo, PlatformFailure> {
        switch settable() {
        case .failure(let failure):
            return .failure(positionFailure(for: failure.code, isFullscreen: isFullscreen))
        case .success(false):
            return .failure(positionFailure(for: .failure, isFullscreen: isFullscreen))
        case .success(true):
            break
        }
        let go = admit()
        guard go == .write else { return .success(go) }
        let code = write()
        return code == .success ? .success(.write) : .failure(positionFailure(for: code, isFullscreen: isFullscreen))
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
