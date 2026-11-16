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

    /// The app's standard windows and sheets, each registered and handed to `take` inside the read, on
    /// the app's queue, once every window has been read. Window ids are resolved only for elements the
    /// registry does not know yet.
    func windows<T: Sendable>(of app: AppInfo27, take: @escaping @Sendable (Entry) -> T) async -> [T] {
        let pid = app.pid
        return await axQueue.run(pid: pid) {
            let known = self.registry.elements(pid: pid)
            let reads = AXWindowAccess.windows(of: pid).compactMap { element -> ElementRead? in
                let resolveID = !known.contains(AXElementBox(element))
                guard case .success(let window) = Windows27.read(element, pid: pid, resolveID: resolveID) else { return nil }
                return Windows27.isTracked(window.attributes) ? window : nil
            }
            return reads.map { take(self.register($0, app: app)) }
        }
    }

    /// Registers any window element, tracked or not: the focused path accepts dialogs and palettes.
    func register(_ window: ElementRead, app: AppInfo27) -> Entry {
        let registration = registry.register(window.element, pid: app.pid, windowID: window.windowID)
        let snapshot = Windows27.snapshot(handle: registration.handle, app: app, attributes: window.attributes)
        return Entry(snapshot: snapshot, element: window.element, isNew: registration.isNew)
    }
}
