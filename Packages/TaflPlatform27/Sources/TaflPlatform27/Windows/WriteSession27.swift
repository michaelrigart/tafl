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
    private let settable: @Sendable (AXUIElement, String) -> Result<Bool, AXFailure>
    private let isEnded = Mutex(false)

    init(
        pid: pid_t,
        element: AXElementBox,
        axQueue: AXQueue,
        leases: WriteLeases,
        restoresEnhancedUI: Bool,
        settable: @escaping @Sendable (AXUIElement, String) -> Result<Bool, AXFailure> = { AXWindowAccess.settability($0, attribute: $1) }
    ) {
        self.pid = pid
        self.settable = settable
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

    /// Handed to `take` on the app's queue as the frame is read.
    func readFrame<T: Sendable>(take: @escaping @Sendable (ScreenRect) -> T) async -> Result<T, PlatformFailure> {
        let element = element
        let result = await axQueue.run(pid: pid) {
            AXWindowAccess.frame(element.element).map { take(Windows27.screenRect($0)) }
        }
        return result.mapError { Windows27.failure(for: $0.code) }
    }

    func setSize(_ size: ScreenSize, admit: @escaping @Sendable () -> WriteGo) async -> Result<WriteGo, PlatformFailure> {
        let element = element
        return await axQueue.run(pid: pid) {
            let go = admit()
            guard go == .write else { return .success(go) }
            let code = AXWindowAccess.setSize(element.element, CGSize(width: size.width, height: size.height))
            if let failure = Windows27.sizeFailure(for: code) { return .failure(failure) }
            return .success(.write)
        }
    }

    /// The settability query comes first and `admit` after it: the query can block on an app that
    /// does not answer, and a stop that arrives meanwhile must still refuse the write.
    func setPosition(
        _ point: ScreenPoint,
        admit: @escaping @Sendable () -> WriteGo
    ) async -> Result<WriteGo, PlatformFailure> {
        let element = element
        let settable = settable
        return await axQueue.run(pid: pid) {
            let target = element.element
            return Windows27.writePosition(
                settable: { settable(target, kAXPositionAttribute) },
                admit: admit,
                write: { AXWindowAccess.setPosition(target, CGPoint(x: point.x, y: point.y)) },
                isFullscreen: { WindowQueries27.live.fullscreen(of: target) })
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
