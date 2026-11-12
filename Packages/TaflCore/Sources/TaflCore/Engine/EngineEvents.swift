import Foundation

extension WindowEngine {
    func listen() {
        guard !isStopping else { return }
        eventTask = Task { [platform] in
            for await event in platform.events {
                await self.handle(event)
                self.activity.receivedEvent()
            }
        }
    }

    /// Deals with one event. What needs a read from an app, or a placement, runs beside the loop
    /// (`track`); what the order of events decides runs here. A window's end reaches the owner from
    /// the platform, in its app's order; the engine only drops its own bookkeeping.
    func handle(_ event: PlatformEvent) async {
        switch event {
        case .windowMoved(let window), .windowResized(let window):
            noteWindowMove()
            readFrame(of: window)
        case .windowCreated(let snapshot):
            windowCreated(snapshot)
        case .titleChanged(let window, _):
            titleChanged(window)
        case .windowDestroyed(let window):
            frameReads[window] = nil
            titleCheck.forget(window)
            eventsHandled += 1
        case .appQuit(let pid):
            unobservable[pid] = nil
            pendingRetries.remove(pid)
            platformRetries.remove(pid)
            reportedUnobservable.remove(pid)
            restartJournal?.quit(pid: pid)
            frameReads = frameReads.filter { $0.key.pid != pid }
            eventsHandled += 1
        case .appLaunched:
            eventsHandled += 1
        case .observability(let pid, let bundleID, let missing, let retrying):
            observability(pid: pid, bundleID: bundleID, missing: missing, retrying: retrying)
            eventsHandled += 1
        case .reconfigurationBegan:
            reconfigurationBegan()
            eventsHandled += 1
        case .reconfigurationEnded:
            reconfigurationEnded()
            eventsHandled += 1
        }
    }

    // MARK: Window frames

    /// Reads the window's frame through the owner, which judges it and records what it implies as
    /// it is read. One window's reads follow one another; another window's are not held up by them.
    private func readFrame(of window: WindowHandle) {
        let previous = frameReads[window]
        let platform = platform
        let owner = owner
        frameReads[window] = track {
            await previous?.value
            _ = await platform.snapshot(of: window, take: owner.take)
        }
    }

    // MARK: New windows

    /// Places a new window when a layout is active and has an entry for it. The announcement's
    /// reading reached the owner as it was read; the window counts as new only when that reading
    /// was the first Tafl had of it, and nothing has touched it since. A layout applied after the
    /// placement was planned overtakes it.
    private func windowCreated(_ snapshot: WindowSnapshot) {
        let window = snapshot.handle
        guard !isStopping,
              !isFrozen,
              snapshot.isPlaceable,
              let definition = activeLayout.definition(in: config),
              owner.placesAtCreation(window)
        else {
            eventsHandled += 1
            return
        }
        let request = LayoutPlanner.requests(
            definition, windows: [snapshot], displays: knownDisplays, source: .newWindow(layout: definition.name)
        ).first
        titleCheck.created(window, at: clock.now, applied: request)
        guard let request else {
            eventsHandled += 1
            return
        }
        let since = reconfigurations.current
        let application = layoutApplications.current
        track { _ = await self.run([request], since: since, application: application) }
    }

    /// The first title change of a new window gets one more look at the layout's entries. Whether
    /// the window was touched is known once the frames read before it have reached the owner. A
    /// layout applied after the title changed overtakes the placement.
    private func titleChanged(_ window: WindowHandle) {
        let time = clock.now
        let since = isFrozen ? nil : reconfigurations.current
        let application = layoutApplications.current
        let reading = frameReads[window]
        track {
            await reading?.value
            await self.recheckTitle(window, at: time, since: since, application: application)
        }
    }

    private func recheckTitle(_ window: WindowHandle, at time: Duration, since: Int?, application: Int) async {
        guard let applied = titleCheck.titleChanged(window, at: time, touched: owner.isTouched(window)),
              let since,
              !isStopping,
              !isFrozen,
              let definition = activeLayout.definition(in: config)
        else { return }
        await placeAfterTitleChange(window, in: definition, applied: applied, since: since, application: application)
    }

    private func placeAfterTitleChange(
        _ window: WindowHandle,
        in definition: LayoutDefinition,
        applied: MoveRequest?,
        since: Int,
        application: Int
    ) async {
        let displays = knownDisplays
        guard case .success(let snapshot) = await platform.snapshot(of: window, take: owner.take), snapshot.isPlaceable,
              let request = LayoutPlanner.requests(
                  definition, windows: [snapshot], displays: displays, source: .newWindow(layout: definition.name)
              ).first
        else { return }
        if let applied, applied.spec == request.spec, applied.display == request.display { return }
        _ = await run([request], since: since, application: application)
    }
}
