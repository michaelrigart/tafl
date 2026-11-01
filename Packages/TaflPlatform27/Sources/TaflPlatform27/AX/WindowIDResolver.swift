import ApplicationServices
import CoreGraphics
import Darwin

public enum WindowIDResolver {
    public enum ResolvedBy: Sendable, Equatable {
        case privateSymbol
        case windowList
    }

    public struct WindowListEntry: Sendable, Equatable {
        public var pid: pid_t
        public var id: UInt32
        public var bounds: CGRect

        public init(pid: pid_t, id: UInt32, bounds: CGRect) {
            self.pid = pid
            self.id = id
            self.bounds = bounds
        }
    }

    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError

    private static let getWindow: GetWindow? = {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(rtldDefault, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: GetWindow.self)
    }()

    public static var privateSymbolAvailable: Bool { getWindow != nil }

    public static func windowID(_ element: AXUIElement, pid: pid_t, frame: CGRect) -> (UInt32, ResolvedBy)? {
        windowID(element, pid: pid, frame: frame, privateLookup: privateSymbolID, windowList: { windowList() })
    }

    /// The window server's windows. `all` includes windows on other Spaces and off screen.
    public static func windowList(all: Bool = false) -> [WindowListEntry] {
        let options: CGWindowListOption = [all ? .optionAll : .optionOnScreenOnly, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return infos.compactMap { info in
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
            else { return nil }
            return WindowListEntry(pid: pid, id: id, bounds: bounds)
        }
    }

    static func windowID(
        _ element: AXUIElement, pid: pid_t, frame: CGRect,
        privateLookup: (AXUIElement) -> UInt32?,
        windowList: () -> [WindowListEntry]
    ) -> (UInt32, ResolvedBy)? {
        if let id = privateLookup(element) { return (id, .privateSymbol) }
        // First match, as in Rectangle: nothing guarantees which window a pid and frame name.
        if !frame.isNull, let entry = windowList().first(where: { $0.pid == pid && $0.bounds == frame }) {
            return (entry.id, .windowList)
        }
        return nil
    }

    private static func privateSymbolID(_ element: AXUIElement) -> UInt32? {
        guard let getWindow else { return nil }
        var id: UInt32 = 0
        return getWindow(element, &id) == .success ? id : nil
    }
}
