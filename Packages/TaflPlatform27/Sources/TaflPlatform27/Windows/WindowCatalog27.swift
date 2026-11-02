import ApplicationServices
import TaflCore

/// Reads an app's windows and registers them, for enumeration and for the catch-up after an app
/// starts being observed.
final class WindowCatalog27: Sendable {
    struct Entry: Sendable, Equatable {
        var snapshot: WindowSnapshot
        var element: AXElementBox
        /// False when the registry already had the window.
        var isNew: Bool
    }

    private let registry: WindowRegistry
    private let axQueue: AXQueue

    init(registry: WindowRegistry, axQueue: AXQueue) {
        self.registry = registry
        self.axQueue = axQueue
    }

    /// The app's standard windows and sheets. Window ids are resolved only for elements the registry
    /// does not know yet.
    func windows(of app: AppInfo27) async -> [Entry] {
        let pid = app.pid
        let known = await registry.elements(pid: pid)
        let reads = await axQueue.run(pid: pid) {
            AXWindowAccess.windows(of: pid).compactMap { element -> ElementRead? in
                let resolveID = !known.contains(AXElementBox(element))
                guard case .success(let window) = Windows27.read(element, pid: pid, resolveID: resolveID) else { return nil }
                return Windows27.isTracked(window.attributes) ? window : nil
            }
        }
        var entries: [Entry] = []
        for window in reads { entries.append(await register(window, app: app)) }
        return entries
    }

    /// Registers any window element, tracked or not: the focused path accepts dialogs and palettes.
    func register(_ window: ElementRead, app: AppInfo27) async -> Entry {
        let registration = await registry.register(window.element, pid: app.pid, windowID: window.windowID)
        let snapshot = Windows27.snapshot(handle: registration.handle, app: app, attributes: window.attributes)
        return Entry(snapshot: snapshot, element: window.element, isNew: registration.isNew)
    }
}
