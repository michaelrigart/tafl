import ApplicationServices
import Synchronization
import TaflCore

/// One lease on an app's windows. Opened by `begin`, which switches Enhanced UI off per the
/// policy; `end()` restores it and gives the lease back. Every Accessibility call runs on the
/// app's `AXQueue`.
final class WriteSession27: WriteSession {
    private let pid: pid_t
    private let element: AXElementBox
    private let axQueue: AXQueue
    private let leases: WriteLeases
    private let restoresEnhancedUI: Bool
    private let isEnded = Mutex(false)

    private init(pid: pid_t, element: AXElementBox, axQueue: AXQueue, leases: WriteLeases, restoresEnhancedUI: Bool) {
        self.pid = pid
        self.element = element
        self.axQueue = axQueue
        self.leases = leases
        self.restoresEnhancedUI = restoresEnhancedUI
    }

    /// Waits for the app's lease, then switches Enhanced UI off.
    static func begin(
        element: AXElementBox, app: AppInfo27, assistiveTechnologyOn: Bool, axQueue: AXQueue, leases: WriteLeases
    ) async -> WriteSession27 {
        let pid = app.pid
        await leases.acquire(pid: pid)
        let bundleID = app.bundleID
        let restores = await axQueue.run(pid: pid) {
            EnhancedUIPolicy.begin(
                bundleID: bundleID, assistiveTechnologyOn: assistiveTechnologyOn,
                read: { AXWindowAccess.enhancedUserInterface(app: pid) },
                write: { _ = AXWindowAccess.setEnhancedUserInterface(app: pid, $0) })
        }
        return WriteSession27(pid: pid, element: element, axQueue: axQueue, leases: leases, restoresEnhancedUI: restores)
    }

    func readFrame() async -> Result<ScreenRect, PlatformFailure> {
        let element = element
        let result = await axQueue.run(pid: pid) { AXWindowAccess.frame(element.element) }
        return result.map(Windows27.screenRect).mapError { Windows27.failure(for: $0.code) }
    }

    func setSize(_ size: ScreenSize) async -> Result<Void, PlatformFailure> {
        let element = element
        let code = await axQueue.run(pid: pid) {
            AXWindowAccess.setSize(element.element, CGSize(width: size.width, height: size.height))
        }
        if let failure = Windows27.sizeFailure(for: code) { return .failure(failure) }
        return .success(())
    }

    func setPosition(_ point: ScreenPoint) async -> Result<Void, PlatformFailure> {
        let element = element
        return await axQueue.run(pid: pid) {
            let target = element.element
            return Windows27.writePosition(
                settable: { AXWindowAccess.settability(target, attribute: kAXPositionAttribute) },
                write: { AXWindowAccess.setPosition(target, CGPoint(x: point.x, y: point.y)) },
                isFullscreen: { AXWindowAccess.isFullscreen(target) ?? false })
        }
    }

    func end() async {
        guard isEnded.withLock({ ended in
            defer { ended = true }
            return !ended
        }) else { return }
        if restoresEnhancedUI {
            let pid = pid
            await axQueue.run(pid: pid) {
                EnhancedUIPolicy.end(restore: true, write: { _ = AXWindowAccess.setEnhancedUserInterface(app: pid, $0) })
            }
        }
        await leases.release(pid: pid)
    }
}
