import Foundation
import Synchronization

/// The newest reading Tafl has accepted for each window, and the frame it showed: one value per
/// window, shared by the writer, which judges every reading of a window against it, and the memory
/// keeper, which changes where Tafl placed a window only from a reading at least as new.
final class WindowReadings: Sendable {
    /// What a reading says when it is judged against the newest accepted for its window.
    enum Judgement: Equatable {
        /// Older than the newest accepted reading: it says nothing.
        case stale
        /// The first reading of the window Tafl accepts.
        case unseen
        /// Within a point of the newest frame, or the newest frame is not known.
        case unchanged
        /// Somewhere else: someone moved the window.
        case moved
    }

    struct Newest: Sendable {
        var readAt: ContinuousClock.Instant
        /// Nil while a write that may have moved the window has not been read back.
        var frame: ScreenRect?
    }

    private struct State {
        var gate = ReadingGate<WindowHandle>()
        var frames: [WindowHandle: ScreenRect] = [:]
    }

    private static let tolerance = 1.0
    private let state = Mutex(State())

    func accepts(_ window: WindowHandle, readAt: ContinuousClock.Instant) -> Bool {
        state.withLock { $0.gate.accepts(window, readAt: readAt) }
    }

    func newest(_ window: WindowHandle) -> Newest? {
        state.withLock { state in
            state.gate.newest(window).map { Newest(readAt: $0, frame: state.frames[window]) }
        }
    }

    /// Judges a reading against the newest accepted for its window and, unless it is stale,
    /// accepts it: it becomes the newest.
    func judge(_ window: WindowHandle, _ reading: FrameReading) -> Judgement {
        state.withLock { state in
            let seen = state.gate.newest(window) != nil
            guard state.gate.admit(window, readAt: reading.readAt) else { return .stale }
            let previous = state.frames[window]
            state.frames[window] = reading.frame
            guard seen else { return .unseen }
            guard let previous, !previous.isClose(to: reading.frame, within: Self.tolerance) else { return .unchanged }
            return .moved
        }
    }

    /// Accepts what a request rests on once it ends, unless a newer reading came first.
    func settle(_ window: WindowHandle, _ newest: Newest) {
        state.withLock { state in
            guard state.gate.admit(window, readAt: newest.readAt) else { return }
            state.frames[window] = newest.frame
        }
    }

    /// Accepts the reading as the first Tafl has of the window; one it already has stands.
    func firstSeen(_ window: WindowHandle, _ reading: FrameReading) {
        state.withLock { state in
            guard state.gate.newest(window) == nil else { return }
            state.gate.admit(window, readAt: reading.readAt)
            state.frames[window] = reading.frame
        }
    }

    func forget(_ window: WindowHandle) {
        state.withLock { state in
            state.gate.forget { $0 == window }
            state.frames[window] = nil
        }
    }

    func forget(pid: Int32) {
        state.withLock { state in
            state.gate.forget { $0.pid == pid }
            state.frames = state.frames.filter { $0.key.pid != pid }
        }
    }
}
