import AppKit
import TaflCore
import TaflPlatform27

@main
final class TaflApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    static func main() {
        let app = NSApplication.shared
        let delegate = TaflApp()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let probeArguments = Probe.arguments(from: CommandLine.arguments) {
            Probe.run(arguments: probeArguments)
            return
        }
        #endif
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.split.2x2", accessibilityDescription: "Tafl")
        let menu = NSMenu()
        menu.addItem(withTitle: "Quit Tafl", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
        Log.app.notice("Tafl started")
    }
}
