import AppKit
import ApplicationServices
import CoreGraphics

enum DockReader27 {
    private static let bundleIdentifier = "com.apple.dock"

    /// The Dock's Accessibility reads run on `axQueue`'s serial queue for the Dock's process.
    static func read(axQueue: AXQueue, screenFrames: [Coordinates27.AXRect]) async -> DockState {
        let autoHidden = isAutoHidden()
        var frame: CGRect?
        if !autoHidden, let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first?.processIdentifier {
            frame = await axQueue.run(pid: pid) { listFrame(pid: pid) }
        }
        return DockState(isAutoHidden: autoHidden, frame: frame.map(Coordinates27.AXRect.init), screenFrames: screenFrames)
    }

    static func isAutoHidden() -> Bool {
        let domain = bundleIdentifier as CFString
        _ = CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue("autohide" as CFString, domain) as? Bool ?? false
    }

    static func listFrame(pid: pid_t) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement]
        else { return nil }
        for child in children {
            var role: AnyObject?
            guard AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role) == .success,
                  (role as? String) == kAXListRole
            else { continue }
            if case .success(let frame) = AXWindowAccess.frame(child), !frame.isNull { return frame }
        }
        return nil
    }
}
