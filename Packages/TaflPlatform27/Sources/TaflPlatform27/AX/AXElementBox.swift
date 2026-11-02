import ApplicationServices

/// An `AXUIElement` that can cross a concurrency boundary. Only `WindowRegistry` stores one, and
/// only code running on that app's `AXQueue` calls Accessibility with it.
public struct AXElementBox: @unchecked Sendable, Equatable { // reason: AXUIElement is an immutable CF reference; every call made with it runs on its app's AXQueue
    public let element: AXUIElement

    public init(_ element: AXUIElement) { self.element = element }

    public static func == (lhs: AXElementBox, rhs: AXElementBox) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }
}
