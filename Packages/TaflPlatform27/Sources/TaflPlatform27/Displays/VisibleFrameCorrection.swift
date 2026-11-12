import CoreGraphics

public struct DockState: Equatable, Sendable {
    public var isAutoHidden: Bool
    /// The Dock's Accessibility list frame; nil when it could not be read.
    public var frame: Coordinates27.AXRect?
    /// Every display's frame, to find the one the Dock sits on.
    public var screenFrames: [Coordinates27.AXRect]

    public init(isAutoHidden: Bool, frame: Coordinates27.AXRect?, screenFrames: [Coordinates27.AXRect]) {
        self.isAutoHidden = isAutoHidden
        self.frame = frame
        self.screenFrames = screenFrames
    }
}

/// Rectangle v2.0.4's Dock and menu bar corrections. On macOS 27.2 the auto-hidden Dock reserved
/// nothing and `visibleFrame` was current a few seconds after a Dock change, so the corrections
/// change nothing there; they stay for a later macOS (spec, "Measured on macOS 27.2").
public enum VisibleFrameCorrection {
    private enum Edge: Equatable {
        case left, right, bottom
    }

    private static let edgeTolerance: CGFloat = 24
    private static let minimumReliableInset: CGFloat = 8
    private static let maximumInsetRatio: CGFloat = 0.33

    public static func corrected(
        visible: Coordinates27.AXRect, frame: Coordinates27.AXRect, dock: DockState?, notchInset: CGFloat
    ) -> Coordinates27.AXRect {
        var result = visible.rect
        if let dock {
            result = mirrored(correctedForDock(
                screenFrame: mirrored(frame.rect), visibleFrame: mirrored(visible.rect),
                screenFrames: dock.screenFrames.map { mirrored($0.rect) },
                dockFrame: dock.frame.map { mirrored($0.rect) },
                dockAutoHideEnabled: dock.isAutoHidden))
        }
        return Coordinates27.AXRect(clearingNotch(result, frame: frame.rect, notchInset: notchInset))
    }

    /// Rectangle works with the origin at the bottom-left; mirroring y about any axis turns the
    /// Accessibility space into that one, and back.
    private static func mirrored(_ rect: CGRect) -> CGRect {
        guard !rect.isNull else { return rect }
        return CGRect(x: rect.minX, y: -rect.maxY, width: rect.width, height: rect.height)
    }

    private static func clearingNotch(_ visible: CGRect, frame: CGRect, notchInset: CGFloat) -> CGRect {
        let top = frame.minY + notchInset
        guard !visible.isNull, notchInset > 0, visible.minY < top, visible.maxY > top else { return visible }
        return CGRect(x: visible.minX, y: top, width: visible.width, height: visible.maxY - top)
    }

    private static func correctedForDock(
        screenFrame: CGRect, visibleFrame: CGRect, screenFrames: [CGRect], dockFrame: CGRect?,
        dockAutoHideEnabled: Bool
    ) -> CGRect {
        guard !screenFrame.isNull, !visibleFrame.isNull else { return visibleFrame }

        if dockAutoHideEnabled {
            return reclaimDockEdges(from: visibleFrame, screenFrame: screenFrame, preservingSmallInsets: true)
        }

        guard
            let dockFrame,
            !dockFrame.isNull,
            dockFrame.width > 0,
            dockFrame.height > 0,
            let dockScreenFrame = dockScreenFrame(for: dockFrame, screenFrames: screenFrames),
            let edge = dockEdge(for: dockFrame, screenFrame: dockScreenFrame)
        else {
            return visibleFrame
        }

        let dockInset = dockInset(for: dockFrame, screenFrame: dockScreenFrame, edge: edge)
        let maximumInset = (edge == .bottom ? dockScreenFrame.height : dockScreenFrame.width) * maximumInsetRatio
        guard dockInset > 0.5, dockInset <= maximumInset else { return visibleFrame }

        guard screenFrame.equalTo(dockScreenFrame) else {
            return reclaimDockEdges(from: visibleFrame, screenFrame: screenFrame)
        }

        let reportedInset = reportedInset(for: visibleFrame, screenFrame: screenFrame, edge: edge)
        let correctedInset = reportedInset > minimumReliableInset
            ? reportedInset
            : dockInset

        var correctedFrame = reclaimDockEdges(from: visibleFrame, screenFrame: screenFrame)
        let correctedMaxY = correctedFrame.maxY
        switch edge {
        case .left:
            correctedFrame.origin.x = screenFrame.minX + correctedInset
            correctedFrame.size.width = screenFrame.maxX - correctedFrame.minX
        case .right:
            correctedFrame.size.width = screenFrame.maxX - correctedInset - correctedFrame.minX
        case .bottom:
            correctedFrame.origin.y = screenFrame.minY + correctedInset
            correctedFrame.size.height = correctedMaxY - correctedFrame.minY
        }

        guard correctedFrame.width > 0, correctedFrame.height > 0 else { return visibleFrame }
        return correctedFrame
    }

    private static func dockScreenFrame(for dockFrame: CGRect, screenFrames: [CGRect]) -> CGRect? {
        let candidates = screenFrames
            .compactMap { screenFrame -> (frame: CGRect, overlap: CGFloat)? in
                let intersection = screenFrame.intersection(dockFrame)
                guard !intersection.isNull else { return nil }
                return (screenFrame, intersection.width * intersection.height)
            }
            .sorted { $0.overlap > $1.overlap }

        guard
            let candidate = candidates.first,
            candidate.overlap >= dockFrame.width * dockFrame.height * 0.5
        else {
            return nil
        }
        if candidates.count > 1, abs(candidate.overlap - candidates[1].overlap) < 1 {
            return nil
        }
        return candidate.frame
    }

    private static func dockEdge(for dockFrame: CGRect, screenFrame: CGRect) -> Edge? {
        let intersection = screenFrame.intersection(dockFrame)
        guard !intersection.isNull else { return nil }

        if intersection.width >= intersection.height,
           intersection.minY - screenFrame.minY <= edgeTolerance {
            return .bottom
        }
        if intersection.height > intersection.width {
            if intersection.minX - screenFrame.minX <= edgeTolerance {
                return .left
            }
            if screenFrame.maxX - intersection.maxX <= edgeTolerance {
                return .right
            }
        }
        return nil
    }

    private static func dockInset(for dockFrame: CGRect, screenFrame: CGRect, edge: Edge) -> CGFloat {
        switch edge {
        case .left:
            return max(0, dockFrame.maxX - screenFrame.minX)
        case .right:
            return max(0, screenFrame.maxX - dockFrame.minX)
        case .bottom:
            return max(0, dockFrame.maxY - screenFrame.minY)
        }
    }

    private static func reportedInset(for visibleFrame: CGRect, screenFrame: CGRect, edge: Edge) -> CGFloat {
        switch edge {
        case .left:
            return max(0, visibleFrame.minX - screenFrame.minX)
        case .right:
            return max(0, screenFrame.maxX - visibleFrame.maxX)
        case .bottom:
            return max(0, visibleFrame.minY - screenFrame.minY)
        }
    }

    private static func reclaimDockEdges(
        from visibleFrame: CGRect, screenFrame: CGRect, preservingSmallInsets: Bool = false
    ) -> CGRect {
        let leftInset = reportedInset(for: visibleFrame, screenFrame: screenFrame, edge: .left)
        let rightInset = reportedInset(for: visibleFrame, screenFrame: screenFrame, edge: .right)
        let bottomInset = reportedInset(for: visibleFrame, screenFrame: screenFrame, edge: .bottom)
        let preservedLeftInset = preservingSmallInsets && leftInset <= minimumReliableInset ? leftInset : 0
        let preservedRightInset = preservingSmallInsets && rightInset <= minimumReliableInset ? rightInset : 0
        let preservedBottomInset = preservingSmallInsets && bottomInset <= minimumReliableInset ? bottomInset : 0
        let maxY = min(visibleFrame.maxY, screenFrame.maxY)
        let minY = screenFrame.minY + preservedBottomInset
        let width = screenFrame.width - preservedLeftInset - preservedRightInset
        guard maxY > minY, width > 0 else { return visibleFrame }
        return CGRect(x: screenFrame.minX + preservedLeftInset, y: minY, width: width, height: maxY - minY)
    }
}
