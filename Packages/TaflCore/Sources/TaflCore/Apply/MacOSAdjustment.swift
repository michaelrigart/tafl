import Foundation

public struct AdjustmentCase: Sendable {
    public var written: WritePart
    /// The expected frame before the write.
    public var before: ScreenRect
    /// The frame read back.
    public var after: ScreenRect
    public var targetVisible: ScreenRect
    public var displays: [Display]

    public init(written: WritePart, before: ScreenRect, after: ScreenRect, targetVisible: ScreenRect, displays: [Display]) {
        self.written = written
        self.before = before
        self.after = after
        self.targetVisible = targetVisible
        self.displays = displays
    }
}

/// A change macOS makes to the part Tafl did not write, which is not an external change.
public struct MacOSAdjustment: Sendable {
    public var name: String
    public var explains: @Sendable (AdjustmentCase) -> Bool

    public init(name: String, explains: @escaping @Sendable (AdjustmentCase) -> Bool) {
        self.name = name
        self.explains = explains
    }

    /// A position write moved the window onto another display (macOS 27.2). A height taller than the
    /// visible frame became the height that ends at the visible bottom; a window that already fits
    /// keeps its height.
    ///
    /// What was measured: five clamps, all at the visible top, where "ends at the visible bottom" and
    /// "the visible height" agree. The bottom form (a clamp at any other y) and the width clamp (a
    /// width wider than the visible frame becoming its visible width) are inferred; none was observed.
    public static let sizeClampedToDisplay = MacOSAdjustment(name: "sizeClampedToDisplay") { adjustment in
        guard adjustment.written == .position,
              let before = DisplayLocator.display(containing: adjustment.before, in: adjustment.displays),
              let after = DisplayLocator.display(containing: adjustment.after, in: adjustment.displays),
              before != after
        else { return false }
        let visible = after.visibleFrame
        let height = adjustment.before.height > visible.height
            ? visible.maxY - adjustment.after.minY
            : adjustment.before.height
        return abs(adjustment.after.width - min(adjustment.before.width, visible.width)) <= 1
            && abs(adjustment.after.height - height) <= 1
    }

    /// The adjustments measured on macOS 27.2 (spec, "Measured on macOS 27.2").
    public static let measured27: [MacOSAdjustment] = [.sizeClampedToDisplay]
}
