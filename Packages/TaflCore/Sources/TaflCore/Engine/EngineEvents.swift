import Foundation

extension WindowEngine {
    func listen() {
        eventTask = Task { [platform] in
            for await event in platform.events {
                await self.handle(event)
            }
        }
    }

    /// Deals with one event. What needs a read from an app, or a placement, runs beside the loop
    /// (`track`); what the order of events decides runs here.
    func handle(_ event: PlatformEvent) async {
        switch event {
        case .windowMoved(let window), .windowResized(let window):
            noteWindowMove()
            // One window's frames are judged in order; another window's are not held up by it.
            let earlier = frameTasks[window]
            frameTasks[window] = track {
                await earlier?.value
                await self.frameChanged(window)
            }
        case .windowCreated(let snapshot):
            await windowCreated(snapshot)
        case .titleChanged(let window, _):
            titleChanged(window)
        case .windowDestroyed(let window):
            await writer.forget(window)
            titleCheck.forget(window)
            movedExternally.remove(window)
            frameTasks[window] = nil
            await memory.update { $0.forget(window) }
            eventsHandled += 1
        case .appQuit(let pid):
            unobservablePIDs.remove(pid)
            frameTasks = frameTasks.filter { $0.key.pid != pid }
            await memory.update { $0.forget(pid: pid) }
            eventsHandled += 1
        case .appLaunched:
            eventsHandled += 1
        case .unobservable(let pid, let bundleID, _):
            if unobservablePIDs.insert(pid).inserted { report(.unobservable(bundleID: bundleID)) }
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

    /// Decides whose the window's new frame is through the writer, and keeps the memory in step.
    func frameChanged(_ window: WindowHandle) async {
        guard case .success(let snapshot) = await platform.snapshot(of: window) else { return }
        switch await writer.observe(window, frame: snapshot.frame) {
        case .heldForWrite:
            break
        case .own:
            await recordLastKnownLive(snapshot)
        case .external:
            movedExternally.insert(window)
            await memory.update { $0.recordExternalChange(window) }
            await recordLastKnownLive(snapshot)
        }
    }

    // MARK: New windows

    /// Records the window's frame, and places it when a layout is active and has an entry for it.
    private func windowCreated(_ snapshot: WindowSnapshot) async {
        movedExternally.remove(snapshot.handle)
        await recordLastKnownLive(snapshot)
        guard !isFrozen,
              snapshot.isPlaceable,
              !unobservablePIDs.contains(snapshot.handle.pid),
              let definition = activeLayout.definition(in: config)
        else {
            eventsHandled += 1
            return
        }
        let request = LayoutPlanner.requests(
            definition, windows: [snapshot], displays: knownDisplays, source: .newWindow(layout: definition.name)
        ).first
        titleCheck.created(snapshot.handle, at: clock.now, applied: request)
        guard let request else {
            eventsHandled += 1
            return
        }
        track { _ = await self.run([request]) }
    }

    /// The first title change of a new window gets one more look at the layout's entries. Whether
    /// the window was touched is known once the frames that came before have been judged.
    private func titleChanged(_ window: WindowHandle) {
        let time = clock.now
        let judging = frameTasks[window]
        track {
            await judging?.value
            await self.recheckTitle(window, at: time)
        }
    }

    private func recheckTitle(_ window: WindowHandle, at time: Duration) async {
        let touched = movedExternally.contains(window)
        guard let applied = titleCheck.titleChanged(window, at: time, touched: touched),
              !isFrozen,
              !unobservablePIDs.contains(window.pid),
              let definition = activeLayout.definition(in: config)
        else { return }
        await placeAfterTitleChange(window, in: definition, applied: applied)
    }

    private func placeAfterTitleChange(
        _ window: WindowHandle,
        in definition: LayoutDefinition,
        applied: MoveRequest?
    ) async {
        guard case .success(let snapshot) = await platform.snapshot(of: window), snapshot.isPlaceable,
              let request = LayoutPlanner.requests(
                  definition, windows: [snapshot], displays: knownDisplays, source: .newWindow(layout: definition.name)
              ).first
        else { return }
        if let applied, applied.spec == request.spec, applied.display == request.display { return }
        _ = await run([request])
    }

    // MARK: Last-known frames

    /// Records one window's frame for the current setup, unless a change is in progress.
    func recordLastKnownLive(_ snapshot: WindowSnapshot) async {
        guard !isFrozen else { return }
        await recordLastKnown([snapshot], displays: knownDisplays, ifUnchangedSince: reconfigurations.current)
    }

    /// Records the frames of the windows that can be placed and are observed, relative to the
    /// display each is on. With `ifUnchangedSince`, nothing is recorded once a reconfiguration
    /// has begun since.
    func recordLastKnown(
        _ windows: [WindowSnapshot],
        displays: [Display],
        ifUnchangedSince count: Int? = nil
    ) async {
        let setup = DisplaySetup(displays)
        let entries = windows.compactMap { window -> (WindowHandle, ScreenRect, Display)? in
            guard window.isPlaceable,
                  !unobservablePIDs.contains(window.handle.pid),
                  let display = DisplayLocator.display(containing: window.frame, in: displays)
            else { return nil }
            return (window.handle, window.frame, display)
        }
        let reconfigurations = reconfigurations
        await memory.update { memory in
            if let count, reconfigurations.current != count { return }
            for (handle, frame, display) in entries {
                memory.recordLastKnown(handle, frame: frame, display: display, setup: setup)
            }
        }
    }
}
