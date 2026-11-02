import AppKit
import TaflCore

/// A short message on the display a failed action belongs to. It never takes focus.
final class FailureOverlay {
    static let displayTime = Duration.milliseconds(1500)

    private let clock: any TaflClock
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private var hideTask: Task<Void, Never>?

    init(clock: any TaflClock) {
        self.clock = clock
        panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 20, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: background.centerYAnchor),
        ])
        panel.contentView = background
    }

    func show(_ kind: FailureKind, on display: DisplayIdentity?) {
        label.stringValue = kind.message
        let size = NSSize(width: label.fittingSize.width + 56, height: label.fittingSize.height + 36)
        let frame = screen(for: display).frame
        panel.setFrame(
            NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height),
            display: true)
        panel.orderFrontRegardless()
        hideTask?.cancel()
        hideTask = Task {
            try? await clock.sleep(for: Self.displayTime)
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
        }
    }

    private func screen(for display: DisplayIdentity?) -> NSScreen {
        if let display, let match = NSScreen.screens.first(where: { identity(of: $0)?.identifier == display.identifier }) { return match }
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func identity(of screen: NSScreen) -> DisplayIdentity? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let id = number.uint32Value
        return DisplayIdentity(
            name: screen.localizedName, vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id),
            serial: CGDisplaySerialNumber(id))
    }
}
