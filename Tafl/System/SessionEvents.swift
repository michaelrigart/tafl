import AppKit
import TaflPlatform27

/// The system moments Tafl reacts to: wake, the user's session coming back, sleep and a changed
/// input source.
final class SessionEvents {
    typealias Handler = @MainActor () -> Void

    private let onWake: Handler
    private let onSessionActive: Handler
    private let onWillSleep: Handler
    private let onInputSourceChanged: Handler
    private var workspaceTokens: [NSObjectProtocol] = []
    private var inputSourceToken: NSObjectProtocol?

    init(
        onWake: @escaping Handler,
        onSessionActive: @escaping Handler,
        onWillSleep: @escaping Handler,
        onInputSourceChanged: @escaping Handler
    ) {
        self.onWake = onWake
        self.onSessionActive = onSessionActive
        self.onWillSleep = onWillSleep
        self.onInputSourceChanged = onInputSourceChanged
    }

    func start() {
        observe(NSWorkspace.didWakeNotification, onWake)
        observe(NSWorkspace.sessionDidBecomeActiveNotification, onSessionActive)
        observe(NSWorkspace.willSleepNotification, onWillSleep)
        inputSourceToken = KeyboardLayoutReader27.observeChanges { [onInputSourceChanged] in
            MainActor.assumeIsolated { onInputSourceChanged() }
        }
    }

    func stop() {
        for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        workspaceTokens = []
        if let inputSourceToken { DistributedNotificationCenter.default().removeObserver(inputSourceToken) }
        inputSourceToken = nil
    }

    private func observe(_ name: Notification.Name, _ handler: @escaping Handler) {
        workspaceTokens.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: name, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { handler() }
        })
    }
}
