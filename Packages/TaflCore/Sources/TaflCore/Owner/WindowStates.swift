import Foundation

/// Every window's state, and the rules a reading or a request step applies to it. `WindowOwner`
/// holds it behind its lock, and each method is one step: whatever a reading implies is recorded in
/// the step that judges it.
struct WindowStates {
    struct Window {
        /// The frame Tafl expects the window at. The first reading sets it (to a placed record's
        /// achieved frame, from disk, when the window is at it), and so do an external change and a
        /// request's own reads: Resolve's, its read-backs and readings while a write is in flight.
        /// Any other reading judged Tafl's own leaves it, so small moves can't add up; after a
        /// request it is the frame achieved.
        var frame: ScreenRect
        /// Moved by someone else, or the target of a user action, since Tafl first read it.
        var touched = false
        /// The first reading was the window's creation announcement, and whether its creation
        /// placement runs is not decided yet.
        var awaitsCreationPlacement = false
        var request: Request?
    }

    /// A request, from Resolve's reading until it ends.
    struct Request {
        let number: Int
        let start: ScreenRect
        /// The reconfiguration epoch it began in.
        let epoch: Int
        /// The layout application it is part of; nil for a request no layout application stops.
        let layoutApplication: Int?
        /// Its first write has begun.
        var wrote = false
        /// A reading after Resolve's showed that someone else moved the window.
        var interrupted = false
        /// The task running it was cancelled: by a newer request for the window, or by Tafl stopping.
        var cancelled = false
        var inFlight: WriteInFlight?
    }

    let check: FrameCheck
    private(set) var windows: [WindowHandle: Window] = [:]
    /// The per-window part of the memory: placed records, restore chains and last-known frames.
    private(set) var memory = WindowMemory()
    /// The displays last-known frames are recorded for.
    private(set) var recordingDisplays: [Display] = []
    /// While a display change is in progress, no last-known frame is recorded.
    private(set) var isFrozen = false
    /// Apps whose moves and resizes Tafl can't observe: no last-known frame is recorded for them.
    private var leftOut: Set<Int32> = []
    /// Bumped when a display reconfiguration begins: a request begun earlier writes no more.
    private(set) var epoch = 0
    /// The newest layout application begun: a request of an older one writes no more.
    private(set) var layoutApplication = 0
    private var nextRequest = 0

    init(check: FrameCheck) {
        self.check = check
    }

    // MARK: Readings

    /// Judges a reading against the frame Tafl expects, or, while a write is in flight, against the
    /// frame before it; then records what it implies. An external change becomes the frame expected.
    /// A reading in flight is checked as the write's read-back is, and like it sets the frame
    /// expected; any other reading judged Tafl's own leaves it. A first reading is never a move, but
    /// a placed record from the memory that the window has left counts as undone by someone else.
    mutating func read(_ window: WindowHandle, _ frame: ScreenRect, placeable: Bool, announced: Bool = false) -> ReadingVerdict {
        let verdict: ReadingVerdict
        if var state = windows[window] {
            let inFlight = state.request?.inFlight
            let isOwn = check.isOwn(frame, expected: state.frame, inFlight: inFlight)
            if !isOwn {
                state.touched = true
                state.request?.interrupted = true
                memory.recordExternalChange(window)
            }
            if !isOwn || inFlight != nil { state.frame = frame }
            windows[window] = state
            verdict = isOwn ? .own : .external
        } else {
            var expected = frame
            if let placed = memory.placed[window] {
                if memory.isAtAchievedFrame(window, frame: frame) {
                    expected = placed.achieved
                } else {
                    memory.recordExternalChange(window)
                }
            }
            windows[window] = Window(frame: expected, awaitsCreationPlacement: announced)
            verdict = .first
        }
        if placeable { recordLastKnown(window, frame) }
        return verdict
    }

    private mutating func recordLastKnown(_ window: WindowHandle, _ frame: ScreenRect) {
        guard !isFrozen, !leftOut.contains(window.pid),
              let display = DisplayLocator.display(containing: frame, in: recordingDisplays)
        else { return }
        memory.recordLastKnown(window, frame: frame, display: display, setup: DisplaySetup(recordingDisplays))
    }

    // MARK: Requests

    /// Resolve's reading, judged as one taken before the request (a move closes the old chain but
    /// interrupts nothing); the request starts at it, and so does the frame it expects. A request
    /// still under way for the window is over.
    mutating func beginRequest(_ snapshot: WindowSnapshot, layoutApplication: Int? = nil) -> RequestStart {
        let window = snapshot.handle
        windows[window]?.request = nil
        _ = read(window, snapshot.frame, placeable: snapshot.isPlaceable)
        windows[window]?.frame = snapshot.frame
        nextRequest += 1
        windows[window]?.request = Request(
            number: nextRequest, start: snapshot.frame, epoch: epoch, layoutApplication: layoutApplication
        )
        return RequestStart(
            ticket: RequestTicket(window: window, number: nextRequest),
            placement: memory.placement(of: window)
        )
    }

    /// Whether the request may go on. Every condition that stops a request is here, so a write's
    /// admission sees each of them: the request is over, interrupted, cancelled, begun before a
    /// reconfiguration, or part of a layout application a newer one has overtaken. Before its first
    /// write, a request that yields to touch is declined for a window that has been touched.
    func checkpoint(_ ticket: RequestTicket, firstWrite: FirstWrite? = nil) -> WriteGo {
        guard let request = current(ticket) else { return .cancelled }
        if request.interrupted { return .interrupted }
        guard !request.cancelled, request.epoch == epoch, !isOvertaken(request) else { return .cancelled }
        if !request.wrote, firstWrite?.yieldsToTouch == true, isTouched(ticket.window) { return .declined }
        return .write
    }

    private func isOvertaken(_ request: Request) -> Bool {
        request.layoutApplication.map { $0 != layoutApplication } ?? false
    }

    /// The task running the request was cancelled.
    mutating func cancel(_ ticket: RequestTicket) {
        guard current(ticket) != nil else { return }
        windows[ticket.window]?.request?.cancelled = true
    }

    /// A write's admission, just before it is made. The first opens the restore chain at the start
    /// when asked to.
    mutating func willWrite(
        _ ticket: RequestTicket,
        _ part: WritePart,
        targetVisible: ScreenRect,
        displays: [Display],
        firstWrite: FirstWrite
    ) -> WriteGo {
        let go = checkpoint(ticket, firstWrite: firstWrite)
        guard go == .write, var state = windows[ticket.window], var request = state.request else { return go }
        if !request.wrote {
            if let display = firstWrite.opensChainOn {
                memory.openChain(ticket.window, before: request.start, on: display)
            }
            request.wrote = true
        }
        request.inFlight = WriteInFlight(part: part, before: state.frame, targetVisible: targetVisible, displays: displays)
        state.request = request
        windows[ticket.window] = state
        return .write
    }

    /// The write did not happen, or no one knows if it did: nothing is in flight any more.
    mutating func writeFailed(_ ticket: RequestTicket) {
        guard current(ticket) != nil else { return }
        windows[ticket.window]?.request?.inFlight = nil
    }

    /// The request's own read, after its write or before its reapply: judged as any reading, and
    /// the write it checks is no longer in flight. What it read is the frame the request expects.
    mutating func readBack(_ ticket: RequestTicket, _ frame: ScreenRect) -> ReadBack {
        guard current(ticket) != nil else { return .ended }
        _ = read(ticket.window, frame, placeable: true)
        windows[ticket.window]?.frame = frame
        windows[ticket.window]?.request?.inFlight = nil
        return windows[ticket.window]?.request?.interrupted == true ? .interrupted : .own(frame)
    }

    /// Ends the request and records what it did on the window's placement in the same step. A window
    /// that is gone, or whose request another took the place of, records nothing.
    mutating func endRequest(_ ticket: RequestTicket, recording applied: Applied?) -> RequestEnding {
        guard let request = current(ticket) else { return RequestEnding(interrupted: false, wrote: false) }
        windows[ticket.window]?.request = nil
        let ending = RequestEnding(interrupted: request.interrupted, wrote: request.wrote)
        var placement = memory.placement(of: ticket.window)
        applied?.record(ending, &placement)
        memory.setPlacement(placement, of: ticket.window)
        return ending
    }

    private func current(_ ticket: RequestTicket) -> Request? {
        guard let request = windows[ticket.window]?.request, request.number == ticket.number else { return nil }
        return request
    }

    // MARK: Touch and creation

    mutating func touch(_ window: WindowHandle) {
        windows[window]?.touched = true
    }

    func isTouched(_ window: WindowHandle) -> Bool {
        windows[window]?.touched ?? false
    }

    /// Whether the window's creation placement may run: its first reading was its announcement and
    /// nothing has touched it. Answered once.
    mutating func placesAtCreation(_ window: WindowHandle) -> Bool {
        guard let state = windows[window], state.awaitsCreationPlacement else { return false }
        windows[window]?.awaitsCreationPlacement = false
        return !state.touched
    }

    // MARK: Lifetimes

    mutating func destroyed(_ window: WindowHandle) {
        windows[window] = nil
        memory.forget(window)
    }

    mutating func quit(pid: Int32) {
        windows = windows.filter { $0.key.pid != pid }
        memory.forget(pid: pid)
    }

    // MARK: Recording last-known frames

    mutating func reconfigurationBegan() {
        isFrozen = true
        epoch += 1
    }

    mutating func layoutApplicationBegan(_ application: Int) {
        layoutApplication = application
    }

    mutating func recordLastKnown(for displays: [Display]) {
        recordingDisplays = displays
        isFrozen = false
    }

    mutating func freezeLastKnown(on displays: [Display]) {
        recordingDisplays = displays
        isFrozen = true
    }

    mutating func leaveOut(_ pids: Set<Int32>) {
        leftOut = pids
    }

    // MARK: Memory

    mutating func loadWindows(from loaded: WindowMemory) {
        memory = WindowMemory(placed: loaded.placed, restore: loaded.restore, lastKnown: loaded.lastKnown)
    }

    mutating func forgetEntries(of pids: Set<Int32>) {
        memory.forget(pids: pids)
    }
}
