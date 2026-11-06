import ApplicationServices
import CoreGraphics

public struct AXFailure: Error, Equatable, Sendable {
    public let code: AXError

    public init(_ code: AXError) { self.code = code }
}

public enum AXWindowAccess {
    public static func focusedWindow(of pid: pid_t) -> AXUIElement? {
        try? findFocusedWindow(of: pid).get()
    }

    /// Rectangle's front-window lookup. It stops at the first `kAXErrorCannotComplete`, so an app that
    /// does not answer costs one timeout, not one per fallback; any other failure tries the next lookup.
    public static func findFocusedWindow(of pid: pid_t) -> Result<AXUIElement, AXFailure> {
        lookUpFocusedWindow(
            focused: { elementResult(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute) },
            first: { windowsResult(of: pid).map(\.first) },
            systemWide: {
                systemWideFocusedWindow(
                    of: pid, systemWide: AXUIElementCreateSystemWide(), pidOf: Self.pid, asking: .live)
            })
    }

    static func lookUpFocusedWindow<Element>(
        focused: () -> Result<Element, AXFailure>,
        first: () -> Result<Element?, AXFailure>,
        systemWide: () -> Result<Element?, AXFailure>
    ) -> Result<Element, AXFailure> {
        switch focused() {
        case .success(let window): return .success(window)
        case .failure(let failure) where failure.code == .cannotComplete: return .failure(failure)
        case .failure: break
        }
        switch first() {
        case .success(let window?): return .success(window)
        case .failure(let failure) where failure.code == .cannotComplete: return .failure(failure)
        case .success(nil), .failure: break
        }
        switch systemWide() {
        case .success(let window?): return .success(window)
        case .failure(let failure) where failure.code == .cannotComplete: return .failure(failure)
        case .success(nil), .failure: return .failure(AXFailure(.noValue))
        }
    }

    public static func windows(of pid: pid_t) -> [AXUIElement] {
        (try? windowsResult(of: pid).get()) ?? []
    }

    public static func windowsResult(of pid: pid_t) -> Result<[AXUIElement], AXFailure> {
        copyResult(AXUIElementCreateApplication(pid), kAXWindowsAttribute).map { $0 as? [AXUIElement] ?? [] }
    }

    public static func frame(_ element: AXUIElement) -> Result<CGRect, AXFailure> {
        let position = pointValue(element, kAXPositionAttribute)
        guard case .success(let origin) = position else { return .failure(position.failure) }
        let size = sizeValue(element, kAXSizeAttribute)
        guard case .success(let extent) = size else { return .failure(size.failure) }
        return .success(CGRect(origin: origin, size: extent))
    }

    public static func setSize(_ element: AXUIElement, _ size: CGSize) -> AXError {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return .illegalArgument }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }

    public static func setPosition(_ element: AXUIElement, _ position: CGPoint) -> AXError {
        var position = position
        guard let value = AXValueCreate(.cgPoint, &position) else { return .illegalArgument }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    public static func isSettable(_ element: AXUIElement, attribute: String) -> Bool {
        (try? settability(element, attribute: attribute).get()) ?? false
    }

    /// Whether the attribute is settable, or why that could not be told (a timeout is not "no").
    public static func settability(_ element: AXUIElement, attribute: String) -> Result<Bool, AXFailure> {
        var settable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return result == .success ? .success(settable.boolValue) : .failure(AXFailure(result))
    }

    public static func title(_ element: AXUIElement) -> String? {
        copyValue(element, kAXTitleAttribute) as? String
    }

    public static func role(_ element: AXUIElement) -> String? {
        copyValue(element, kAXRoleAttribute) as? String
    }

    public static func subrole(_ element: AXUIElement) -> String? {
        copyValue(element, kAXSubroleAttribute) as? String
    }

    public static func isMinimized(_ element: AXUIElement) -> Bool? {
        windowElement(for: element).flatMap(isMinimized(window:))
    }

    public static func isMinimized(window: AXUIElement) -> Bool? {
        copyValue(window, kAXMinimizedAttribute) as? Bool
    }

    /// Rectangle's test: a full-screen window's AXFullScreenButton has the zoom subrole.
    public static func isFullscreen(_ element: AXUIElement) -> Bool? {
        windowElement(for: element).flatMap(isFullscreen(window:))
    }

    public static func isFullscreen(window: AXUIElement) -> Bool? {
        guard let button = elementValue(window, kAXFullScreenButtonAttribute),
              let subrole = subrole(button)
        else { return nil }
        return subrole == kAXZoomButtonSubrole
    }

    /// The undocumented `AXFullScreen` attribute, read next to `isFullscreen` so the two can be compared.
    public static func fullScreenAttribute(_ element: AXUIElement) -> Bool? {
        copyValue(element, "AXFullScreen") as? Bool
    }

    public static func minimumSize(_ element: AXUIElement) -> CGSize? {
        if case .success(let size) = sizeValue(element, "AXMinSize") { return size }
        if case .success(let size) = sizeValue(element, "AXMinimumSize") { return size }
        return nil
    }

    public static func enhancedUserInterface(app pid: pid_t) -> Bool? {
        copyValue(AXUIElementCreateApplication(pid), "AXEnhancedUserInterface") as? Bool
    }

    @discardableResult
    public static func setEnhancedUserInterface(app pid: pid_t, _ enabled: Bool) -> AXError {
        AXUIElementSetAttributeValue(
            AXUIElementCreateApplication(pid), "AXEnhancedUserInterface" as CFString, enabled as CFBoolean)
    }

    public static func pid(_ element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    /// Rectangle's `windowElement`: a window is itself; otherwise its containing window;
    /// otherwise an element with the AXStandardWindow subrole is itself (Emacs 28 exposes
    /// its window as an AXTextField without an AXWindow attribute).
    static func resolveWindowElement<Element, Failure: Error>(
        _ element: Element, isWindow: Bool?,
        containingWindow: () throws(Failure) -> Element?,
        subrole: () throws(Failure) -> String?
    ) throws(Failure) -> Element? {
        if isWindow == true { return element }
        if let window = try containingWindow() { return window }
        return try subrole() == kAXStandardWindowSubrole ? element : nil
    }

    private static func windowElement(for element: AXUIElement) -> AXUIElement? {
        resolveWindowElement(
            element,
            isWindow: role(element).map { $0 == kAXWindowRole },
            containingWindow: { elementValue(element, kAXWindowAttribute) },
            subrole: { subrole(element) })
    }

    /// The last resort in Rectangle's front-window lookup: the system-wide focused element,
    /// or its window. Kept only when it belongs to the app asked about, which is checked before
    /// anything is asked of it: another app that does not answer is never taken for this one. An
    /// element's window belongs to its app.
    static func systemWideFocusedWindow<Element>(
        of pid: pid_t,
        systemWide: Element,
        pidOf: (Element) -> pid_t?,
        asking ask: WindowQueries27<Element>
    ) -> Result<Element?, AXFailure> {
        Result { () throws(AXFailure) -> Element? in
            guard let focused = try ask.element(systemWide, kAXFocusedUIElementAttribute).answer(),
                  pidOf(focused) == pid
            else { return nil }
            return try ask.windowElement(of: focused)
        }
    }

    private static func copyResult(_ element: AXUIElement, _ attribute: String) -> Result<AnyObject, AXFailure> {
        var value: AnyObject?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success else { return .failure(AXFailure(status)) }
        guard let value else { return .failure(AXFailure(.noValue)) }
        return .success(value)
    }

    private static func copyValue(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        try? copyResult(element, attribute).get()
    }

    /// A value of another type than asked for is `illegalArgument`, as for a point or a size.
    static func stringResult(_ element: AXUIElement, _ attribute: String) -> Result<String, AXFailure> {
        copyResult(element, attribute).flatMap { ($0 as? String).map { .success($0) } ?? .failure(AXFailure(.illegalArgument)) }
    }

    static func boolResult(_ element: AXUIElement, _ attribute: String) -> Result<Bool, AXFailure> {
        copyResult(element, attribute).flatMap { ($0 as? Bool).map { .success($0) } ?? .failure(AXFailure(.illegalArgument)) }
    }

    static func elementResult(_ element: AXUIElement, _ attribute: String) -> Result<AXUIElement, AXFailure> {
        copyResult(element, attribute).flatMap { value in
            CFGetTypeID(value) == AXUIElementGetTypeID() ? .success(value as! AXUIElement) : .failure(AXFailure(.illegalArgument))
        }
    }

    private static func elementValue(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        try? elementResult(element, attribute).get()
    }

    private static func pointValue(_ element: AXUIElement, _ attribute: String) -> Result<CGPoint, AXFailure> {
        axValue(element, attribute, type: .cgPoint).flatMap { value in
            var point = CGPoint.zero
            return AXValueGetValue(value, .cgPoint, &point) ? .success(point) : .failure(AXFailure(.illegalArgument))
        }
    }

    static func sizeValue(_ element: AXUIElement, _ attribute: String) -> Result<CGSize, AXFailure> {
        axValue(element, attribute, type: .cgSize).flatMap { value in
            var size = CGSize.zero
            return AXValueGetValue(value, .cgSize, &size) ? .success(size) : .failure(AXFailure(.illegalArgument))
        }
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String, type: AXValueType) -> Result<AXValue, AXFailure> {
        var raw: AnyObject?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &raw)
        guard status == .success else { return .failure(AXFailure(status)) }
        guard let raw, CFGetTypeID(raw) == AXValueGetTypeID(), AXValueGetType(raw as! AXValue) == type else {
            return .failure(AXFailure(.illegalArgument))
        }
        return .success(raw as! AXValue)
    }
}

private extension Result where Failure == AXFailure {
    var failure: AXFailure {
        if case .failure(let failure) = self { return failure }
        return AXFailure(.success)
    }
}
