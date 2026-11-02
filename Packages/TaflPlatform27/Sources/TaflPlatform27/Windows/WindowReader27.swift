import ApplicationServices

/// The Accessibility reads the event translator needs, as a seam: the live one runs on the app's
/// `AXQueue`, a test supplies its own.
struct WindowReader27: Sendable {
    /// Nil when the element is not a standard window or sheet, or could not be read.
    var readTracked: @Sendable (_ element: AXElementBox, _ pid: pid_t, _ resolveID: Bool) async -> ElementRead?
    var title: @Sendable (_ element: AXElementBox, _ pid: pid_t) async -> String
    /// Nil when the process is gone.
    var app: @Sendable (_ pid: pid_t) -> AppInfo27?

    static func live(axQueue: AXQueue) -> WindowReader27 {
        WindowReader27(
            readTracked: { box, pid, resolveID in
                await axQueue.run(pid: pid) { () -> ElementRead? in
                    guard Windows27.isTrackedElement(box.element),
                          case .success(let window) = Windows27.read(box.element, pid: pid, resolveID: resolveID)
                    else { return nil }
                    return window
                }
            },
            title: { box, pid in
                await axQueue.run(pid: pid) { AXWindowAccess.title(box.element) ?? "" }
            },
            app: { AppInfo27.running(pid: $0) })
    }
}
