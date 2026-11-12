import ApplicationServices

/// An `AXUIElement` that can cross a concurrency boundary. The registry stores it and event or read
/// results carry it; only code running on the app's `AXQueue` calls Accessibility with it.
struct AXElementBox: @unchecked Sendable, Equatable { // reason: AXUIElement is an immutable CF reference; every call made with it runs on its app's AXQueue
    let element: AXUIElement

    init(_ element: AXUIElement) { self.element = element }

    static func == (lhs: AXElementBox, rhs: AXElementBox) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }
}
