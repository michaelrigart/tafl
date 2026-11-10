import AppKit
import SwiftUI

/// Explains the Accessibility permission and sends the user to the right page of System Settings.
final class OnboardingWindow {
    private static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    private var window: NSWindow?

    func show() {
        if window == nil {
            let view = OnboardingView(openSettings: { Self.openAccessibilitySettings() }, reopen: { Relaunch.perform() })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Welcome to Tafl"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func close() {
        window?.close()
        window = nil
    }

    /// Asking once lists Tafl in the Accessibility pane; without it an unsigned build is not there to switch on.
    static func openAccessibilitySettings() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        NSWorkspace.shared.open(settingsURL)
    }
}

private struct OnboardingView: View {
    let openSettings: () -> Void
    let reopen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tafl needs Accessibility access")
                .font(.title2.bold())
            Text("Tafl moves and resizes windows with keyboard shortcuts. macOS only lets an app do that after you allow it in System Settings › Privacy & Security › Device Control and Data Access.")
            Text("Turn Tafl on in that list. Until you do, Tafl registers no shortcuts and moves nothing.")
                .foregroundStyle(.secondary)
            Text("This window closes once Tafl sees the permission. If it stays open after you have turned Tafl on, Reopen Tafl finishes it.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Open Accessibility Settings", action: openSettings)
                    .keyboardShortcut(.defaultAction)
                Button("Reopen Tafl", action: reopen)
            }
        }
        .frame(width: 420)
        .padding(24)
    }
}
