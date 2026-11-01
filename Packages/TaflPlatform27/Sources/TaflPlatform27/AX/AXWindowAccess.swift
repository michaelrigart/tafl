import ApplicationServices
import CoreGraphics

public struct AXFailure: Error, Equatable, Sendable {
    public let code: AXError

    public init(_ code: AXError) { self.code = code }
}

public enum AXWindowAccess {
    public static func focusedWindow(of pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        if let focused = elementValue(app, kAXFocusedWindowAttribute) { return focused }
        if let first = windows(of: pid).first { return first }
        return systemWideFocusedWindow(pid: pid)
    }

    public static func windows(of pid: pid_t) -> [AXUIElement] {
        guard let value = copyValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute) else { return [] }
        return value as? [AXUIElement] ?? []
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
        var settable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return result == .success && settable.boolValue
    }

    public static func title(_ element: AXUIElement) -> String? {
        copyValue(element, kAXTitleAttribute) as? String
    }

    public static func subrole(_ element: AXUIElement) -> String? {
        copyValue(element, kAXSubroleAttribute) as? String
    }

    public static func isMinimized(_ element: AXUIElement) -> Bool? {
        guard let window = windowElement(for: element) else { return nil }
        return copyValue(window, kAXMinimizedAttribute) as? Bool
    }

    /// Rectangle's test: a full-screen window's AXFullScreenButton has the zoom subrole.
    public static func isFullscreen(_ element: AXUIElement) -> Bool? {
        guard let window = windowElement(for: element),
              let button = elementValue(window, kAXFullScreenButtonAttribute),
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
    static func resolveWindowElement<Element>(
        _ element: Element, isWindow: Bool?,
        containingWindow: () -> Element?,
        subrole: () -> String?
    ) -> Element? {
        if isWindow == true { return element }
        if let window = containingWindow() { return window }
        return subrole() == kAXStandardWindowSubrole ? element : nil
    }

    private static func windowElement(for element: AXUIElement) -> AXUIElement? {
        resolveWindowElement(
            element,
            isWindow: (copyValue(element, kAXRoleAttribute) as? String).map { $0 == kAXWindowRole },
            containingWindow: { elementValue(element, kAXWindowAttribute) },
            subrole: { subrole(element) })
    }

    /// The last resort in Rectangle's front-window lookup: the system-wide focused element,
    /// or its window. Kept only when it belongs to the app asked about.
    private static func systemWideFocusedWindow(pid: pid_t) -> AXUIElement? {
        guard let focused = elementValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute),
              let window = windowElement(for: focused),
              Self.pid(window) == pid
        else { return nil }
        return window
    }

    private static func copyValue(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func elementValue(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copyValue(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func pointValue(_ element: AXUIElement, _ attribute: String) -> Result<CGPoint, AXFailure> {
        axValue(element, attribute, type: .cgPoint).flatMap { value in
            var point = CGPoint.zero
            return AXValueGetValue(value, .cgPoint, &point) ? .success(point) : .failure(AXFailure(.illegalArgument))
        }
    }

    private static func sizeValue(_ element: AXUIElement, _ attribute: String) -> Result<CGSize, AXFailure> {
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
