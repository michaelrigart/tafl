import TaflCore

struct ResolvedWindowID: Sendable, Equatable {
    var id: UInt32
    var by: WindowIDResolver.ResolvedBy
}

/// Maps each `WindowHandle` to its element. A window keeps its handle for as long as its element
/// is registered; when no window id resolves, the handle is synthetic (`isStable == false`).
/// Whether the window's creation has been announced is kept apart from its registration: a query
/// registers windows but never announces them.
actor WindowRegistry {
    enum Announcement: Equatable {
        case announced
        case alreadyAnnounced
        /// The publisher refused: its claim had ended. The window stays unannounced.
        case refused
        case unregistered
    }

    struct Registration: Sendable, Equatable {
        var handle: WindowHandle
        /// False when the element was already registered.
        var isNew: Bool
    }

    private struct Entry {
        var handle: WindowHandle
        var element: AXElementBox
        var announced = false
    }

    private var entries: [Entry] = []
    private var nextSyntheticID: UInt32 = 1

    var count: Int { entries.count }

    func handle(for element: AXElementBox, pid: Int32, windowID: ResolvedWindowID?) -> WindowHandle {
        register(element, pid: pid, windowID: windowID).handle
    }

    /// The handle of a registered element, or a new registration: from `windowID` when it resolved,
    /// otherwise a synthetic one. A registered element keeps the handle it has.
    ///
    /// An id from the private symbol names its window exactly, so a new element for it replaces the old
    /// one. An id from the window list is a guess (a pid and a frame), so when another element already
    /// holds it the newcomer gets a synthetic handle and the holder keeps its own.
    func register(_ element: AXElementBox, pid: Int32, windowID: ResolvedWindowID?) -> Registration {
        if let known = knownHandle(of: element) { return Registration(handle: known, isNew: false) }
        let handle: WindowHandle
        if let windowID, windowID.by == .privateSymbol || !isHeld(pid: pid, windowID: windowID.id) {
            handle = WindowHandle(pid: pid, windowID: windowID.id, isStable: true)
            entries.removeAll { $0.handle == handle }
        } else {
            handle = WindowHandle(pid: pid, windowID: nextSyntheticID, isStable: false)
            nextSyntheticID += 1
        }
        entries.append(Entry(handle: handle, element: element))
        return Registration(handle: handle, isNew: true)
    }

    private func isHeld(pid: Int32, windowID: UInt32) -> Bool {
        entries.contains { $0.handle == WindowHandle(pid: pid, windowID: windowID, isStable: true) }
    }

    func knownHandle(of element: AXElementBox) -> WindowHandle? {
        entries.first { $0.element == element }?.handle
    }

    /// The registered elements of one app, so a reader on its queue can skip id resolution for them.
    func elements(pid: Int32) -> [AXElementBox] {
        entries.filter { $0.handle.pid == pid }.map(\.element)
    }

    func element(for handle: WindowHandle) -> AXElementBox? {
        entries.first { $0.handle == handle }?.element
    }

    /// Announces a registered window's creation, once, in one step of the registry: if it is not
    /// yet announced, `publish` checks its claim and yields the event, and the window is marked
    /// only when it did. Nothing else marks a window announced, and nothing unmarks one.
    func announce(_ snapshot: WindowSnapshot, publish: @Sendable (PlatformEvent) -> Bool) -> Announcement {
        guard let index = entries.firstIndex(where: { $0.handle == snapshot.handle }) else { return .unregistered }
        guard !entries[index].announced else { return .alreadyAnnounced }
        guard publish(.windowCreated(snapshot)) else { return .refused }
        entries[index].announced = true
        return .announced
    }

    /// Removes registrations their owner made, each only while it is still the same: the same handle
    /// for the same element.
    func withdraw(_ registrations: [(handle: WindowHandle, element: AXElementBox)]) {
        entries.removeAll { entry in
            registrations.contains { $0.handle == entry.handle && $0.element == entry.element }
        }
    }

    func remove(_ handle: WindowHandle) {
        entries.removeAll { $0.handle == handle }
    }

    func removeApp(pid: Int32) {
        entries.removeAll { $0.handle.pid == pid }
    }
}
