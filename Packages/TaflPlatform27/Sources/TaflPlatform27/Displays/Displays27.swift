import AppKit
import ApplicationServices
import CoreGraphics
import TaflCore

public enum Displays27 {
    /// Every display in the core's space, top-left first, with the Dock, menu bar and notch taken out
    /// of its visible frame.
    @MainActor
    public static func current() -> [Display] {
        let raw = DisplayReader27.displays()
        return displays(from: raw, dock: DockReader.read(screenFrames: raw.map(\.frame)))
    }

    static func displays(from raw: [RawDisplay27], dock: DockState?) -> [Display] {
        raw.map { display(from: $0, dock: dock) }
            .sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
    }

    static func display(from raw: RawDisplay27, dock: DockState?) -> Display {
        let visible = VisibleFrameCorrection.corrected(
            visible: raw.visibleFrame, frame: raw.frame, dock: dock, notchInset: raw.safeAreaTop)
        return Display(
            identity: DisplayIdentity(name: raw.name, vendor: raw.vendor, model: raw.model, serial: raw.serial),
            frame: screenRect(raw.frame),
            visibleFrame: screenRect(visible))
    }

    private static func screenRect(_ rect: Coordinates27.AXRect) -> ScreenRect {
        ScreenRect(x: rect.rect.minX, y: rect.rect.minY, width: rect.rect.width, height: rect.rect.height)
    }
}

/// The Dock is read on its own serial queue, never the main actor, with Rectangle's short timeout.
private enum DockReader {
    private static let bundleIdentifier = "com.apple.dock"
    private static let queue = DispatchQueue(label: "com.michaelrigart.tafl.ax.dock")

    static func read(screenFrames: [Coordinates27.AXRect]) -> DockState {
        let autoHidden = CFPreferencesCopyAppValue("autohide" as CFString, bundleIdentifier as CFString) as? Bool ?? false
        let frame = autoHidden ? nil : queue.sync { listFrame() }
        return DockState(isAutoHidden: autoHidden, frame: frame.map(Coordinates27.AXRect.init), screenFrames: screenFrames)
    }

    private static func listFrame() -> CGRect? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement]
        else { return nil }
        for child in children {
            var role: AnyObject?
            guard AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role) == .success,
                  (role as? String) == kAXListRole
            else { continue }
            AXUIElementSetMessagingTimeout(child, 0.1)
            if case .success(let frame) = AXWindowAccess.frame(child), !frame.isNull { return frame }
        }
        return nil
    }
}
