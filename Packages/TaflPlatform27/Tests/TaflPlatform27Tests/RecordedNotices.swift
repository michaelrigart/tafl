import Synchronization
import TaflCore

/// Keeps every notice the platform hands the core, in order.
final class RecordedNotices: WindowNotices {
    enum Notice: Equatable {
        case announced(WindowHandle)
        case destroyed(WindowHandle)
        case quit(Int32)
    }

    private let notices = Mutex<[Notice]>([])

    var all: [Notice] { notices.withLock { $0 } }

    func announced(_ snapshot: WindowSnapshot) { notices.withLock { $0.append(.announced(snapshot.handle)) } }
    func destroyed(_ window: WindowHandle) { notices.withLock { $0.append(.destroyed(window)) } }
    func quit(pid: Int32) { notices.withLock { $0.append(.quit(pid)) } }
}
