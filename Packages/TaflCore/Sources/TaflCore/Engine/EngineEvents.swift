import Foundation

/// What an event saw when it arrived: frames read later are recorded for these displays, and
/// only if no reconfiguration has begun since. `since` is nil while a change is in progress.
struct EventContext: Sendable {
    var displays: [Display]
    var since: Int?
}

extension WindowEngine {
    func listen() {
        eventTask = Task { [platform] in
            for await event in platform.events {
                await self.handle(event)
            }
        }
    }

    var currentContext: EventContext {
        EventContext(displays: knownDisplays, since: isFrozen ? nil : reconfigurations.current)
    }

    /// Deals with one event. What needs a read from an app, or a placement, runs beside the loop
    /// (`track`); what the order of events decides runs here.
    func handle(_ event: PlatformEvent) async {
        switch event {
        case .windowMoved(let window), .windowResized(let window):
            noteWindowMove()
            judgeFrame(of: window)
        case .windowCreated(let snapshot):
            await windowCreated(snapshot)
        case .titleChanged(let window, _):
            titleChanged(window)
        case .windowDestroyed(let window):
            frameTasks[window] = nil
            for id in runWindows.keys { runWindows[id]?.remove(window) }
            touched.remove(window)
            titleCheck.forget(window)
            await writer.forget(window)
            await memory.forget(window)
            eventsHandled += 1
        case .appQuit(let pid):
            unobservable[pid] = nil
            reportedUnobservable.remove(pid)
            restartJournal?.quit(pid: pid)
            for id in runWindows.keys { runWindows[id] = runWindows[id]?.filter { $0.pid != pid } }
            frameTasks = frameTasks.filter { $0.key.pid != pid }
            touched = touched.filter { $0.pid != pid }
            await writer.forget(pid: pid)
            await memory.forget(pid: pid)
            eventsHandled += 1
        case .appLaunched(let pid, _):
            await memory.processStarted(pid: pid)
            eventsHandled += 1
        case .unobservable(let pid, let bundleID, let missing):
            learn(pid: pid, bundleID: bundleID, missing: missing)
            eventsHandled += 1
        case .reconfigurationBegan:
            await reconfigurationBegan()
            eventsHandled += 1
        case .reconfigurationEnded:
            reconfigurationEnded()
            eventsHandled += 1
        }
    }

    // MARK: Window frames

    /// One window's frames are judged in order; another window's are not held up by it.
    private func judgeFrame(of window: WindowHandle) {
        let context = currentContext
        let previous = frameTasks[window]
        let token = previous?.token ?? nextFrameToken
        if previous == nil { nextFrameToken += 1 }
        let task = track {
            await previous?.task.value
            await self.frameChanged(window, token: token, context)
        }
        frameTasks[window] = FrameWork(token: token, task: task)
    }

    private func isLive(_ window: WindowHandle, token: Int) -> Bool {
        frameTasks[window]?.token == token
    }

    /// Decides through the writer what the window's new frame says, and keeps the memory in step.
    /// A frame judged while a write runs counts too: the last one the write puts there is the
    /// window's last known frame. A frame read before the window's newest accepted reading says
    /// nothing, and changes nothing.
    private func frameChanged(_ window: WindowHandle, token: Int, _ context: EventContext) async {
        guard case .success(let snapshot) = await platform.snapshot(of: window, take: { $0 }), isLive(window, token: token) else {
            return
        }
        let verdict = await writer.observe(window, frame: snapshot.frame, readAt: snapshot.readAt)
        guard isLive(window, token: token), verdict != .stale else { return }
        if verdict == .external {
            touched.insert(window)
            await memory.recordPlacement(window, readAt: snapshot.readAt) { $0.recordExternalChange() }
            guard isLive(window, token: token) else { return }
        }
        await recordLastKnownLive([snapshot], context)
    }

    // MARK: New windows

    /// Records the window's frame, and places it when a layout is active and has an entry for it.
    /// The engine's state for a window begins when it first sees it, whatever the source. An
    /// announcement for a window it already knows comes late, with a snapshot older than what the
    /// engine has: it writes nothing and places nothing. Otherwise the announced frame is the
    /// first Tafl has of the window, so whichever later reading first finds it elsewhere, an
    /// event's or a placement's, counts as a move.
    private func windowCreated(_ snapshot: WindowSnapshot) async {
        guard await !knows(snapshot.handle) else {
            eventsHandled += 1
            return
        }
        await memory.processStarted(pid: snapshot.handle.pid)
        await writer.firstSeen(snapshot.handle, FrameReading(frame: snapshot.frame, readAt: snapshot.readAt))
        let context = currentContext
        await recordLastKnownLive([snapshot], context)
        guard let since = context.since,
              snapshot.isPlaceable,
              !isLeftOutOfPlacement(pid: snapshot.handle.pid),
              let definition = activeLayout.definition(in: config)
        else {
            eventsHandled += 1
            return
        }
        let request = LayoutPlanner.requests(
            definition, windows: [snapshot], displays: context.displays, source: .newWindow(layout: definition.name)
        ).first
        titleCheck.created(snapshot.handle, at: clock.now, applied: request)
        guard let request else {
            eventsHandled += 1
            return
        }
        track { _ = await self.run([request], since: since) }
    }

    /// Whether the engine has state for the window: it was touched, a frame event for it was
    /// judged, or the memory holds something about it.
    private func knows(_ window: WindowHandle) async -> Bool {
        if touched.contains(window) || frameTasks[window] != nil { return true }
        return await memory.knows(window)
    }

    /// The first title change of a new window gets one more look at the layout's entries. Whether
    /// the window was touched is known once the frames that came before have been judged.
    private func titleChanged(_ window: WindowHandle) {
        let time = clock.now
        let since = isFrozen ? nil : reconfigurations.current
        let judging = frameTasks[window]?.task
        track {
            await judging?.value
            await self.recheckTitle(window, at: time, since: since)
        }
    }

    private func recheckTitle(_ window: WindowHandle, at time: Duration, since: Int?) async {
        guard let applied = titleCheck.titleChanged(window, at: time, touched: touched.contains(window)),
              let since,
              !isStopping,
              !isFrozen,
              !isLeftOutOfPlacement(pid: window.pid),
              let definition = activeLayout.definition(in: config)
        else { return }
        await placeAfterTitleChange(window, in: definition, applied: applied, since: since)
    }

    private func placeAfterTitleChange(
        _ window: WindowHandle,
        in definition: LayoutDefinition,
        applied: MoveRequest?,
        since: Int
    ) async {
        let displays = knownDisplays
        guard case .success(let snapshot) = await platform.snapshot(of: window, take: { $0 }), snapshot.isPlaceable,
              let request = LayoutPlanner.requests(
                  definition, windows: [snapshot], displays: displays, source: .newWindow(layout: definition.name)
              ).first
        else { return }
        if let applied, applied.spec == request.spec, applied.display == request.display { return }
        _ = await run([request], since: since)
    }

    // MARK: Last-known frames

    /// Records frames for the setup of `context`, unless a change was in progress when its event
    /// arrived or one has begun since.
    func recordLastKnownLive(_ windows: [WindowSnapshot], _ context: EventContext) async {
        guard let since = context.since else { return }
        await recordLastKnown(windows: windows, displays: context.displays, since: since)
    }

    /// Records where a request left windows, unless a change is in progress.
    func recordLastKnownLive(_ frames: [KnownFrame], since: Int) async {
        guard !isFrozen else { return }
        await recordLastKnown(frames, displays: knownDisplays, since: since)
    }

    /// Records the frames of the windows that can be placed, relative to the display each is on.
    func recordLastKnown(windows: [WindowSnapshot], displays: [Display], since count: Int? = nil) async {
        let frames = windows.filter(\.isPlaceable).map {
            KnownFrame(handle: $0.handle, frame: $0.frame, readAt: $0.readAt)
        }
        await recordLastKnown(frames, displays: displays, since: count)
    }

    /// Records frames of the apps whose moves are observed, each unless a newer reading of its
    /// window is already recorded for the setup. With `since`, nothing is recorded once a
    /// reconfiguration has begun since, and a frame not recorded holds no later one back.
    func recordLastKnown(_ frames: [KnownFrame], displays: [Display], since count: Int? = nil) async {
        let setup = DisplaySetup(displays)
        let entries = frames.compactMap { known -> (KnownFrame, Display)? in
            guard !isLeftOutOfRules(pid: known.handle.pid),
                  let display = DisplayLocator.display(containing: known.frame, in: displays)
            else { return nil }
            return (known, display)
        }
        let reconfigurations = reconfigurations
        for (known, display) in entries {
            await memory.recordLastKnown(
                known.handle, frame: known.frame, display: display, setup: setup, readAt: known.readAt,
                when: { count.map(reconfigurations.isCurrent) ?? true }
            )
        }
    }
}
