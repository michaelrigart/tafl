import Synchronization
import Testing
import TaflCore

/// Keeps every notice the platform hands the core, in order.
final class RecordedNotices: WindowNotices {
    enum Notice: Equatable {
        case announced(WindowHandle)
        case destroyed(WindowHandle)
        case quit(Int32)
    }

    private let notices = Mutex<[Notice]>([])
    private let received = CountWaiters()

    var all: [Notice] { notices.withLock { $0 } }

    /// Waits until `count` notices have been received.
    func waitForNotices(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
        await received.wait(for: count, sourceLocation: sourceLocation)
    }

    func announced(_ snapshot: WindowSnapshot) { record(.announced(snapshot.handle)) }
    func destroyed(_ window: WindowHandle) { record(.destroyed(window)) }
    func quit(pid: Int32) { record(.quit(pid)) }

    private func record(_ notice: Notice) {
        notices.withLock { $0.append(notice) }
        received.increment()
    }
}
