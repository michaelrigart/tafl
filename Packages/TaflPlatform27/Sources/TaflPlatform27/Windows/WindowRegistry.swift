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

    /// Marks the window's creation announced. False when it already was, or the window is not
    /// registered: the caller announces only on true.
    func announce(_ handle: WindowHandle) -> Bool {
        guard let index = entries.firstIndex(where: { $0.handle == handle }), !entries[index].announced else {
            return false
        }
        entries[index].announced = true
        return true
    }

    /// Takes back what a catch-up whose claim ended did: the windows it registered go, and the
    /// ones it marked announced are not.
    func withdraw(registered: [WindowHandle], announced: [WindowHandle]) {
        entries.removeAll { registered.contains($0.handle) }
        for index in entries.indices where announced.contains(entries[index].handle) {
            entries[index].announced = false
        }
    }

    func remove(_ handle: WindowHandle) {
        entries.removeAll { $0.handle == handle }
    }

    func removeApp(pid: Int32) {
        entries.removeAll { $0.handle.pid == pid }
    }
}
