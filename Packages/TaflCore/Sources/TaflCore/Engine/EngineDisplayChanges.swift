import Foundation

extension WindowEngine {
    // MARK: Reconfigurations

    func reconfigurationBegan() {
        // In one step of the engine: the count stops the runs, and the owner stops recording
        // last-known frames and stops every request begun earlier from writing.
        reconfigurations.begin()
        if changeOrigin == nil { changeOrigin = knownDisplays }
        owner.reconfigurationBegan()
        tracker.began(at: clock.now)
        armSettle()
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
    /// A reconfiguration still open at its cap, the timeout counted from when it opened, counts as
    /// ended then: inputs move only the quiet period, never the cap. Only the wait is replaced by
    /// an input: once the change has settled, the rules run in a task of their own, and nothing
    /// but a new reconfiguration stops them.
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
            wait = (tracker.openedAt ?? clock.now) + timing.reconfigurationTimeout - clock.now
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
        guard reconfigurations.isCurrent(began) else { return }
        let new = await platform.displays()
        guard reconfigurations.isCurrent(began) else { return }
        // A placeholder display (macOS wakes in the dark with one) is no setup: nothing moves, the
        // active layout and the last-known setup stay, and recording stays frozen from `changeOrigin`,
        // so the next real setup is compared with the one before the placeholder.
        guard !new.contains(where: \.isPlaceholder) else { return }
        let old = changeOrigin ?? knownDisplays
        if DisplaySetup(old) == DisplaySetup(new), !rulesStarted {
            // A display that dropped out and came back, or a change of geometry: nothing moves, but
            // frames may have changed while recording was frozen, and no event follows them.
            // The origin goes in the step that resumes recording, so a change that begins during the
            // read starts from the geometry being recorded.
            changeOrigin = nil
            await resumeRecording(for: new)
            await rememberDisplays(new, since: began)
        } else {
            await applyDisplayChange(from: old, to: new, since: began)
        }
    }

    /// Resumes recording last-known frames for `displays` and reads every window into it: frames
    /// that changed while recording was frozen are recorded now, since nothing announces them.
    /// Recording resumes before the first await, so the caller's check of the count before the call
    /// still holds for it.
    private func resumeRecording(for displays: [Display]) async {
        owner.recordLastKnown(for: displays)
        _ = await platform.visibleWindows(take: owner.take)
    }

    /// Stores the displays startup or a settled change recorded last-known frames for, unless a
    /// reconfiguration has begun since `began`. That change stores its own setup when it settles, so
    /// a write that landed after it began would put a replaced setup back. Every write of the
    /// stored displays comes here; the count is checked in the memory's step that writes.
    func rememberDisplays(_ displays: [Display], since began: Int) async {
        let reconfigurations = reconfigurations
        await memory.update { memory in
            if reconfigurations.isCurrent(began) { memory.lastDisplays = displays }
        }
    }

    // MARK: The rules

    /// Handles a display setup that differs from the one before, or whose rules an earlier
    /// change began and did not finish: the active layout ends; each window is handled by the
    /// first rule that applies; a layout that claims the new setup becomes active. A layout
    /// applied since the rules began overtakes them: they send no further request, a request they
    /// sent writes no more, and the claiming layout does not become active. Recording stays frozen
    /// until the rules have run, overtaken or not; then it resumes for the new setup, and the seed
    /// reads every window into it. A reconfiguration that begins meanwhile takes over: the run
    /// stops and leaves the state to the change that follows.
    func applyDisplayChange(from old: [Display], to new: [Display], since began: Int? = nil) async {
        let began = began ?? reconfigurations.current
        guard !isStopping, reconfigurations.isCurrent(began) else { return }
        let application = beginLayoutApplication()
        rulesStarted = true
        let oldSetup = DisplaySetup(old)
        let newSetup = DisplaySetup(new)

        await setActiveLayout(nil)
        let known = await memory.read()
        let visible = await platform.visibleWindows(take: owner.take)
        guard !isStopping, reconfigurations.isCurrent(began) else { return }
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
        let count = await run(requests, since: began, application: application)
        guard !Task.isCancelled, !isStopping, reconfigurations.isCurrent(began) else { return }

        // No await between the check above and this: a reconfiguration that begins from here
        // freezes recording again.
        await resumeRecording(for: new)
        await rememberDisplays(new, since: began)
        // No await between this check and the state it protects. The claiming layout becomes
        // active only now, so a run that was stopped leaves none behind.
        guard reconfigurations.isCurrent(began) else { return }
        changeOrigin = nil
        rulesStarted = false
        if let claiming, layoutApplications.isCurrent(application) { activeLayout.activate(claiming.name, in: config) }
        let layout = activeLayout.name
        await memory.update { $0.activeLayout = layout }
        await save()
        report(.displayChangeHandled(moved: count.moved, failed: count.failed))
    }
}
