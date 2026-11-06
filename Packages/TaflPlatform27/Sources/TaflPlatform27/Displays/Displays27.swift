import TaflCore

public enum Displays27 {
    /// Every display in the core's space, top-left first, with the Dock, menu bar and notch taken out
    /// of its visible frame.
    @MainActor
    public static func current(axQueue: AXQueue) async -> [Display] {
        let raw = DisplayReader27.displays()
        let dock = await DockReader27.read(axQueue: axQueue, screenFrames: raw.map(\.frame))
        return displays(from: raw, dock: dock)
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
