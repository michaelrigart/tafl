import AppKit

/// What the menu shows. The controller draws it and holds nothing else.
struct StatusMenuContent: Equatable {
    var visible = false
    var layouts: [String] = []
    var activeLayout: String?
    var issues: [String] = []
    var canApplyLayouts = false
}

final class StatusItemController: NSObject {
    var onApplyLayout: ((String) -> Void)?
    /// Settings and Capture Current Arrangement are disabled until their handler is set.
    var onOpenSettings: (() -> Void)?
    var onCapture: (() -> Void)?

    var content = StatusMenuContent() {
        didSet { if content != oldValue { rebuild() } }
    }

    private var item: NSStatusItem?

    private func rebuild() {
        guard content.visible else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        let item = self.item ?? makeItem()
        item.menu = makeMenu()
    }

    private func makeItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.split.2x2", accessibilityDescription: "Tafl")
        self.item = item
        return item
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for name in content.layouts {
            let entry = NSMenuItem(title: name, action: #selector(applyLayout(_:)), keyEquivalent: "")
            entry.target = self
            entry.state = name == content.activeLayout ? .on : .off
            entry.isEnabled = content.canApplyLayouts
            menu.addItem(entry)
        }
        if !content.layouts.isEmpty { menu.addItem(.separator()) }
        menu.addItem(action("Capture Current Arrangement", #selector(capture), enabled: onCapture != nil))
        menu.addItem(action("Settings…", #selector(openSettings), enabled: onOpenSettings != nil))
        if !content.issues.isEmpty {
            menu.addItem(.separator())
            for issue in content.issues {
                let line = NSMenuItem(title: issue, action: nil, keyEquivalent: "")
                line.isEnabled = false
                menu.addItem(line)
            }
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Tafl", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    private func action(_ title: String, _ selector: Selector, enabled: Bool) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        entry.target = self
        entry.isEnabled = enabled
        return entry
    }

    @objc private func applyLayout(_ sender: NSMenuItem) {
        onApplyLayout?(sender.title)
    }

    @objc private func capture() {
        onCapture?()
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }
}
