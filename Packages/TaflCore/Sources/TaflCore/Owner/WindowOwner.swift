import Foundation
import Synchronization

/// What a reading said about its window.
public enum ReadingVerdict: Equatable, Sendable {
    /// The first reading Tafl has of the window: never a move.
    case first
    /// Where Tafl's own writes, or nothing at all, left the window.
    case own
    /// Someone else moved the window.
    case external
}

/// Names one request for a window, from Resolve's reading until it ends.
public struct RequestTicket: Hashable, Sendable {
    public let window: WindowHandle
    let number: Int
}

/// What Resolve's reading gives the request.
public struct RequestStart: Sendable {
    public let ticket: RequestTicket
    /// Where Tafl placed the window, and its restore chain, once Resolve's reading was recorded.
    public let placement: WindowPlacement
}

/// What a request does at its first write.
public struct FirstWrite: Equatable, Sendable {
    /// Opens the window's restore chain at the request's start, on this display; nil opens none.
    public var opensChainOn: Display?
    /// Writes nothing once the window has been touched.
    public var yieldsToTouch: Bool

    public init(opensChainOn: Display? = nil, yieldsToTouch: Bool = false) {
        self.opensChainOn = opensChainOn
        self.yieldsToTouch = yieldsToTouch
    }
}

/// Whether a request may write now.
public enum WriteGo: Equatable, Sendable {
    case write
    /// A reading after Resolve's showed that someone else moved the window.
    case interrupted
    /// A display reconfiguration began, or the request is over.
    case cancelled
    /// The window was touched, and the request yields to that.
    case declined
}

/// What the request's own read says.
public enum ReadBack: Equatable, Sendable {
    /// The frame the write left: Tafl's own.
    case own(ScreenRect)
    case interrupted
    /// The request is over, or its window is gone.
    case ended
}

/// How a request ended.
public struct RequestEnding: Equatable, Sendable {
    /// A reading after Resolve's showed that someone else moved the window. That reading recorded it.
    public var interrupted: Bool
    /// The request's first write began.
    public var wrote: Bool
}

/// The one owner of every window's state. Every reading of a window comes here from inside the read
/// (a read's `take`, see `WindowPlatform`), so the owner sees each window's readings in the order they
/// were read. In one step it judges a reading (Tafl's own frame, a named macOS adjustment, or someone
/// else's move) and records what it implies: the touched mark, the placed record and restore chain, the
/// last-known frame for the displays current when it was read, and the frame Tafl expects next. A
/// request runs through it too, from Resolve's reading to its end, which records its outcome in the
/// same step. Nothing else writes a window's state or its memory.
///
/// Every step is short and makes no call out, so the platform can take it on an app's queue.
public final class WindowOwner: WindowNotices {
    private let state: Mutex<WindowStates>

    public init(adjustments: [MacOSAdjustment]) {
        state = Mutex(WindowStates(check: FrameCheck(adjustments: adjustments)))
    }

    // MARK: Readings

    /// Judges and records a reading, and gives it back: a read's `take`.
    public func take(_ snapshot: WindowSnapshot) -> WindowSnapshot {
        read(snapshot)
        return snapshot
    }

    @discardableResult
    func read(_ snapshot: WindowSnapshot) -> ReadingVerdict {
        state.withLock { $0.read(snapshot.handle, snapshot.frame, placeable: snapshot.isPlaceable) }
    }

    public func announced(_ snapshot: WindowSnapshot) {
        state.withLock { _ = $0.read(snapshot.handle, snapshot.frame, placeable: snapshot.isPlaceable, announced: true) }
    }

    public func destroyed(_ window: WindowHandle) {
        state.withLock { $0.destroyed(window) }
    }

    public func quit(pid: Int32) {
        state.withLock { $0.quit(pid: pid) }
    }

    // MARK: Requests

    /// Resolve's reading: it begins the window's request.
    public func beginRequest(_ snapshot: WindowSnapshot) -> RequestStart {
        state.withLock { $0.beginRequest(snapshot) }
    }

    /// Whether the request may go on: not interrupted, over, or begun before a reconfiguration.
    public func checkpoint(_ ticket: RequestTicket) -> WriteGo {
        state.withLock { $0.checkpoint(ticket) }
    }

    /// Before each write: the checkpoint, then the first write's terms, then the write is in flight.
    public func willWrite(
        _ ticket: RequestTicket,
        _ part: WritePart,
        targetVisible: ScreenRect,
        displays: [Display],
        firstWrite: FirstWrite
    ) -> WriteGo {
        state.withLock {
            $0.willWrite(ticket, part, targetVisible: targetVisible, displays: displays, firstWrite: firstWrite)
        }
    }

    public func writeFailed(_ ticket: RequestTicket) {
        state.withLock { $0.writeFailed(ticket) }
    }

    /// The request's own read: a read-back's `take`.
    public func readBack(_ ticket: RequestTicket, _ frame: ScreenRect) -> ReadBack {
        state.withLock { $0.readBack(ticket, frame) }
    }

    /// Ends the request, and records its outcome on the window's placement in the same step.
    @discardableResult
    public func endRequest(
        _ ticket: RequestTicket,
        _ record: (RequestEnding, inout WindowPlacement) -> Void = { _, _ in }
    ) -> RequestEnding {
        state.withLock { $0.endRequest(ticket, record) }
    }

    // MARK: Touch and creation

    /// A user action targets the window.
    public func touch(_ window: WindowHandle) {
        state.withLock { $0.touch(window) }
    }

    public func isTouched(_ window: WindowHandle) -> Bool {
        state.withLock { $0.isTouched(window) }
    }

    /// Whether the window's creation placement may run: its first reading was its announcement and
    /// nothing has touched it. Answered once.
    public func placesAtCreation(_ window: WindowHandle) -> Bool {
        state.withLock { $0.placesAtCreation(window) }
    }

    /// Whether the owner holds any state for the window.
    func knows(_ window: WindowHandle) -> Bool {
        state.withLock { $0.windows[window] != nil }
    }

    // MARK: Recording last-known frames

    /// Stops recording last-known frames, and stops every request begun before now from writing.
    public func reconfigurationBegan() {
        state.withLock { $0.reconfigurationBegan() }
    }

    /// Records last-known frames for these displays from now on.
    public func recordLastKnown(for displays: [Display]) {
        state.withLock { $0.recordLastKnown(for: displays) }
    }

    /// Records no last-known frame, until `recordLastKnown(for:)`, while a change from these displays is handled.
    public func freezeLastKnown(on displays: [Display]) {
        state.withLock { $0.freezeLastKnown(on: displays) }
    }

    /// The apps whose moves and resizes Tafl can't observe: no last-known frame is recorded for them.
    public func leaveOut(pids: Set<Int32>) {
        state.withLock { $0.leaveOut(pids) }
    }

    public var recordingDisplays: [Display] {
        state.withLock { $0.recordingDisplays }
    }

    public var isFrozen: Bool {
        state.withLock { $0.isFrozen }
    }

    // MARK: Memory

    /// The per-window part of the memory.
    public var windowMemory: WindowMemory {
        state.withLock { $0.memory }
    }

    /// Takes the per-window part of a loaded memory.
    public func loadWindows(from memory: WindowMemory) {
        state.withLock { $0.loadWindows(from: memory) }
    }

    /// Drops what a loaded memory holds for these processes' windows.
    public func forgetEntries(of pids: Set<Int32>) {
        state.withLock { $0.forgetEntries(of: pids) }
    }
}
