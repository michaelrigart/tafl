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
    /// A reconfiguration still open after the timeout counts as ended.
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
            await settle()
        } else {
            armSettle()
        }
    }

    private func settle() async {
        let began = reconfigurations.current
        let new = await platform.displays()
        guard reconfigurations.current == began else { return }
        let old = changeOrigin ?? knownDisplays
        if DisplaySetup(old) == DisplaySetup(new) {
            // A display that dropped out and came back, or a change of geometry: nothing moves.
            knownDisplays = new
            changeOrigin = nil
            isFrozen = false
            await memory.update { $0.lastDisplays = new }
        } else {
            await applyDisplayChange(from: old, to: new)
        }
    }

    // MARK: The rules

    /// Handles a display setup that differs from the one before: the active layout ends; each
    /// window is handled by the first rule that applies; a layout that claims the new setup
    /// becomes active. Recording stays frozen until the rules have run, and then the new
    /// setup's frames are seeded. A reconfiguration that begins meanwhile takes over.
    func applyDisplayChange(from old: [Display], to new: [Display]) async {
        let began = reconfigurations.current
        let oldSetup = DisplaySetup(old)
        let newSetup = DisplaySetup(new)

        await setActiveLayout(nil)
        let known = await memory.read()
        let windows = await platform.visibleWindows().map { window in
            WindowAtChange(
                snapshot: window,
                previous: known.lastKnown(window.handle, setup: oldSetup),
                remembered: known.lastKnown(window.handle, setup: newSetup),
                isObserved: !unobservablePIDs.contains(window.handle.pid)
            )
        }
        let claiming = LayoutPlanner.claiming(config.layouts, displays: new)
        let requests = DisplayChangeRules.plan(
            oldDisplays: old, newDisplays: new, windows: windows, claiming: claiming, gap: config.gap
        )
        let count = await run(requests)
        guard reconfigurations.current == began else { return }

        if let claiming { await setActiveLayout(claiming.name) }
        let visible = await platform.visibleWindows()
        let reconfigurations = reconfigurations
        await recordLastKnown(visible, displays: new, ifUnchangedSince: began)
        await memory.update { memory in
            if reconfigurations.current == began { memory.lastDisplays = new }
        }
        // No await between this check and the state it protects.
        guard reconfigurations.current == began else { return }
        knownDisplays = new
        changeOrigin = nil
        isFrozen = false
        report(.displayChangeHandled(moved: count.moved))
    }
}
