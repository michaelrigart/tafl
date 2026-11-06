import Synchronization
import TaflCore

/// Passes the platform's notices on to the ones `startObserving(notices:)` was last given; until
/// then they go nowhere. The caller keeps the app's order: each call runs in the app's serial work.
final class NoticeRelay: WindowNotices {
    private let target = Mutex<(any WindowNotices)?>(nil)

    func relay(to notices: any WindowNotices) {
        target.withLock { $0 = notices }
    }

    func announced(_ snapshot: WindowSnapshot) {
        current?.announced(snapshot)
    }

    func destroyed(_ window: WindowHandle) {
        current?.destroyed(window)
    }

    func quit(pid: Int32) {
        current?.quit(pid: pid)
    }

    private var current: (any WindowNotices)? {
        target.withLock { $0 }
    }
}
