import TaflCore

/// Maps each `WindowHandle` to its element. A window keeps its handle for as long as its element
/// is registered; when no window id resolves, the handle is synthetic (`isStable == false`).
actor WindowRegistry {
    private struct Entry {
        var handle: WindowHandle
        var element: AXElementBox
    }

    private var entries: [Entry] = []
    private var nextSyntheticID: UInt32 = 1

    var count: Int { entries.count }

    /// The handle of a registered element, or a new registration: from `windowID` when it
    /// resolved, otherwise a synthetic one. A registered element keeps the handle it has.
    func handle(for element: AXElementBox, pid: Int32, windowID: UInt32?) -> WindowHandle {
        if let known = knownHandle(of: element) { return known }
        let handle: WindowHandle
        if let windowID {
            handle = WindowHandle(pid: pid, windowID: windowID, isStable: true)
            entries.removeAll { $0.handle == handle }
        } else {
            handle = WindowHandle(pid: pid, windowID: nextSyntheticID, isStable: false)
            nextSyntheticID += 1
        }
        entries.append(Entry(handle: handle, element: element))
        return handle
    }

    func knownHandle(of element: AXElementBox) -> WindowHandle? {
        entries.first { $0.element == element }?.handle
    }

    func element(for handle: WindowHandle) -> AXElementBox? {
        entries.first { $0.handle == handle }?.element
    }

    func remove(_ handle: WindowHandle) {
        entries.removeAll { $0.handle == handle }
    }

    func removeApp(pid: Int32) {
        entries.removeAll { $0.handle.pid == pid }
    }
}
