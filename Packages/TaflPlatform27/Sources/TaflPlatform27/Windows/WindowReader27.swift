import ApplicationServices

/// The Accessibility reads the event translator needs, and its app's queue, as a seam: the live one
/// runs on the app's `AXQueue`, a test supplies its own.
struct WindowReader27: Sendable {
    /// Reads a standard window or sheet and hands it to `then` inside the read, on the app's queue.
    /// Nil when the element is not a standard window or sheet, or could not be read.
    var readTracked: @Sendable (
        _ element: AXElementBox,
        _ pid: pid_t,
        _ resolveID: Bool,
        _ then: @escaping @Sendable (ElementRead) -> WindowCatalog27.Entry
    ) async -> WindowCatalog27.Entry?
    var title: @Sendable (_ element: AXElementBox, _ pid: pid_t) async -> String
    /// Nil when the process is gone.
    var app: @Sendable (_ pid: pid_t) -> AppInfo27?
    /// Runs `work` on the app's queue, after the reads already there, without waiting for it.
    var afterReads: @Sendable (_ pid: pid_t, _ work: @escaping @Sendable () -> Void) -> Void

    static func live(axQueue: AXQueue) -> WindowReader27 {
        WindowReader27(
            readTracked: { box, pid, resolveID, then in
                await axQueue.run(pid: pid) { () -> WindowCatalog27.Entry? in
                    guard Windows27.isTrackedElement(box.element),
                          case .success(let window) = Windows27.read(box.element, pid: pid, resolveID: resolveID)
                    else { return nil }
                    return then(window)
                }
            },
            title: { box, pid in
                await axQueue.run(pid: pid) { AXWindowAccess.title(box.element) ?? "" }
            },
            app: { AppInfo27.running(pid: $0) },
            afterReads: { pid, work in axQueue.enqueue(pid: pid, work) })
    }
}
