#if DEBUG
import AppKit

/// A floating panel that never takes focus, so the window under test keeps it.
final class ProbePanel: NSPanel {
    private let label = NSTextField(wrappingLabelWithString: "")
    private var continuation: CheckedContinuation<Void, Never>?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 150),
            styleMask: [.titled, .utilityWindow, .nonactivatingPanel],
            backing: .buffered, defer: false)
        title = "Tafl probe"
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let button = NSButton(title: "Continue", target: self, action: #selector(continuePressed))
        button.keyEquivalent = "\r"
        let stack = NSStackView(views: [label, button])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 16, right: 16)
        label.preferredMaxLayoutWidth = 388
        contentView = stack
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func pause(_ text: String) async {
        label.stringValue = text
        setContentSize(contentView?.fittingSize ?? frame.size)
        center()
        orderFrontRegardless()
        await withCheckedContinuation { continuation = $0 }
        orderOut(nil)
    }

    @objc private func continuePressed() {
        continuation?.resume()
        continuation = nil
    }
}
#endif
