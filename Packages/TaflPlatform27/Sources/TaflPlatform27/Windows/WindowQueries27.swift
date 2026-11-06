import ApplicationServices
import CoreGraphics

/// The Accessibility queries a window read makes, by attribute, as a seam: the live ones ask the
/// element (on its app's `AXQueue`), a test answers its own. Each gives the value, or the error
/// the query failed with.
struct WindowQueries27<Element> {
    var frame: (Element) -> Result<CGRect, AXFailure>
    var string: (Element, String) -> Result<String, AXFailure>
    var element: (Element, String) -> Result<Element, AXFailure>
    var bool: (Element, String) -> Result<Bool, AXFailure>
    var size: (Element, String) -> Result<CGSize, AXFailure>
    var settable: (Element, String) -> Result<Bool, AXFailure>
}

extension WindowQueries27<AXUIElement> {
    static var live: Self {
        Self(
            frame: AXWindowAccess.frame,
            string: AXWindowAccess.stringResult,
            element: AXWindowAccess.elementResult,
            bool: AXWindowAccess.boolResult,
            size: AXWindowAccess.sizeValue,
            settable: { AXWindowAccess.settability($0, attribute: $1) })
    }
}

extension WindowQueries27 {
    /// The same queries, each failure read as the attribute's absence: a query asked through them
    /// takes its default however it fails, a timeout included.
    var takingDefaults: Self {
        let absent = { (_: AXFailure) in AXFailure(.noValue) }
        return Self(
            frame: { self.frame($0).mapError(absent) },
            string: { self.string($0, $1).mapError(absent) },
            element: { self.element($0, $1).mapError(absent) },
            bool: { self.bool($0, $1).mapError(absent) },
            size: { self.size($0, $1).mapError(absent) },
            settable: { self.settable($0, $1).mapError(absent) })
    }

    /// Rectangle's `windowElement` (see `AXWindowAccess.resolveWindowElement`), asking for the role,
    /// and for the subrole only when it decides.
    func windowElement(of element: Element) throws(AXFailure) -> Element? {
        try windowElement(
            of: element,
            role: string(element, kAXRoleAttribute).answer(),
            subrole: { () throws(AXFailure) in try string(element, kAXSubroleAttribute).answer() })
    }

    /// Whether the element's window is full screen, as a read tells it, or why that could not be told.
    func fullscreen(of element: Element) -> Result<Bool, AXFailure> {
        Result { () throws(AXFailure) in try isFullscreen(element, window: windowElement(of: element)) }
    }

    /// Rectangle's `windowElement` (see `AXWindowAccess.resolveWindowElement`), from a role already read.
    func windowElement(
        of element: Element,
        role: String?,
        subrole: () throws(AXFailure) -> String?
    ) throws(AXFailure) -> Element? {
        try AXWindowAccess.resolveWindowElement(
            element,
            isWindow: role.map { $0 == kAXWindowRole },
            containingWindow: { () throws(AXFailure) in try self.element(element, kAXWindowAttribute).answer() },
            subrole: subrole)
    }

    /// Rectangle's test (a full-screen window's AXFullScreenButton has the zoom subrole), then the
    /// undocumented `AXFullScreen` attribute when that test can't tell.
    func isFullscreen(_ element: Element, window: Element?) throws(AXFailure) -> Bool {
        if let window,
           let button = try self.element(window, kAXFullScreenButtonAttribute).answer(),
           let subrole = try string(button, kAXSubroleAttribute).answer() {
            return subrole == kAXZoomButtonSubrole
        }
        return try bool(element, "AXFullScreen").answer() ?? false
    }
}

extension Result where Failure == AXFailure {
    /// The attribute's value, or nil when the element has none. A query the app did not answer (a
    /// timeout arrives as `cannotComplete`), or one that found the element gone, says nothing about
    /// the attribute: it throws.
    func answer() throws(AXFailure) -> Success? {
        switch self {
        case .success(let value): return value
        case .failure(let failure) where failure.code == .cannotComplete || failure.code == .invalidUIElement: throw failure
        case .failure: return nil
        }
    }
}
