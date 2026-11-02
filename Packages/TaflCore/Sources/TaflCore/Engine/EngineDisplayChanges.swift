import Foundation

extension WindowEngine {
    // MARK: Reconfigurations

    func reconfigurationBegan() async {
        // The count goes first: a request that reads it before the writer's epoch has moved
        // is stopped by one or the other.
        reconfigurations.bump()
        if changeOrigin == nil { changeOrigin = knownDisplays }
        isFrozen = true
        tracker.began(at: clock.now)
        armSettle()
        await writer.reconfigurationBegan()
    }

    func reconfigurationEnded() {
        tracker.ended(at: clock.now)
        armSettle()
    }

    /// Every frame counts as a window move while a change is in progress.
    func noteWindowMove() {
        guard tracker.isChanging else { return }
        tracker.windowMoved(at: clock.now)
        armSettle()
    }

    // MARK: Settling

    /// Waits on the clock for the tracker's deadline, starting over whenever an input moves it.
    /// A reconfiguration still open after the timeout counts as ended. Only the wait is replaced
    /// by an input: once the change has settled, the rules run in a task of their own, and
    /// nothing but a new reconfiguration stops them.
    private func armSettle() {
        settleTask?.cancel()
        guard tracker.isChanging else {
            settleTask = nil
            return
        }
        settleTask = Task { await self.awaitSettle() }
    }

    private func awaitSettle() async {
        let wait: Duration
        let isOpen: Bool
        if let deadline = tracker.deadline {
            wait = deadline - clock.now
            isOpen = false
        } else {
            wait = timing.reconfigurationTimeout
            isOpen = true
        }
        do {
            try await clock.sleep(for: max(wait, .zero))
        } catch {
            return
        }
        // An input that arrived while this woke has started a newer wait.
        if Task.isCancelled { return }
        if isOpen {
            tracker.ended(at: clock.now)
            armSettle()
        } else if tracker.settleIfDue(now: clock.now) {
            // Taken here, with the decision: a reconfiguration that begins before the task first
            // runs must still be seen to have moved the count.
            let began = reconfigurations.current
            rulesTask = Task { await self.settle(since: began) }
        } else {
            armSettle()
        }
    }

    private func settle(since began: Int) async {
        guard reconfigurations.current == began else { return }
        let new = await platform.displays()
        guard reconfigurations.current == began else { return }
        let old = changeOrigin ?? knownDisplays
        if DisplaySetup(old) == DisplaySetup(new), !rulesStarted {
            // A display that dropped out and came back, or a change of geometry: nothing moves.
            knownDisplays = new
            changeOrigin = nil
            isFrozen = false
            await memory.update { $0.lastDisplays = new }
        } else {
            await applyDisplayChange(from: old, to: new, since: began)
        }
    }

    // MARK: The rules

    /// Handles a display setup that differs from the one before, or whose rules an earlier
    /// change began and did not finish: the active layout ends; each window is handled by the
    /// first rule that applies; a layout that claims the new setup becomes active. Recording
    /// stays frozen until the rules have run, and then the new setup's frames are seeded.
    /// A reconfiguration that begins meanwhile takes over: the run stops and leaves the
    /// state to the change that follows.
    func applyDisplayChange(from old: [Display], to new: [Display], since began: Int? = nil) async {
        let began = began ?? reconfigurations.current
        guard reconfigurations.current == began else { return }
        rulesStarted = true
        let oldSetup = DisplaySetup(old)
        let newSetup = DisplaySetup(new)

        await setActiveLayout(nil)
        let known = await memory.read()
        let visible = await platform.visibleWindows()
        guard reconfigurations.current == began else { return }
        let windows = visible.map { window in
            WindowAtChange(
                snapshot: window,
                previous: known.lastKnown(window.handle, setup: oldSetup),
                remembered: known.lastKnown(window.handle, setup: newSetup),
                isObserved: !isLeftOutOfRules(pid: window.handle.pid)
            )
        }
        let claiming = LayoutPlanner.claiming(config.layouts, displays: new)
        let requests = DisplayChangeRules.plan(
            oldDisplays: old, newDisplays: new, windows: windows, claiming: claiming, gap: config.gap
        )
        let count = await run(requests, since: began)
        guard !Task.isCancelled, reconfigurations.current == began else { return }

        let after = await platform.visibleWindows()
        let reconfigurations = reconfigurations
        await recordLastKnown(windows: after, displays: new, since: began)
        await memory.update { memory in
            if reconfigurations.current == began { memory.lastDisplays = new }
        }
        // No await between this check and the state it protects. The claiming layout becomes
        // active only now, so a run that was stopped leaves none behind.
        guard reconfigurations.current == began else { return }
        knownDisplays = new
        changeOrigin = nil
        isFrozen = false
        rulesStarted = false
        if let claiming { activeLayout.activate(claiming.name) }
        let layout = activeLayout.name
        await memory.update { $0.activeLayout = layout }
        await save()
        report(.displayChangeHandled(moved: count.moved, failed: count.failed))
    }
}
