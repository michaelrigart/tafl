#if DEBUG
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import TaflPlatform27

/// The Task 2 feasibility probe. `open /Applications/Tafl.app --args -TaflProbe <subcommand> …`
/// runs one subcommand, logs to the `probe` category and quits.
enum Probe {
    static func arguments(from commandLine: [String]) -> [String]? {
        guard let index = commandLine.firstIndex(of: "-TaflProbe") else { return nil }
        return Array(commandLine[(index + 1)...])
    }

    static func run(arguments: [String]) {
        ProbeLog.start()
        Task {
            await dispatch(arguments)
            ProbeLog.write("probe finished")
            NSApplication.shared.terminate(nil)
        }
    }

    private static let queue = AXQueue()
    private static let panel = ProbePanel()

    private static func dispatch(_ arguments: [String]) async {
        _ = queue // creating the queue sets the 0.5 s messaging timeout before any Accessibility call
        ProbeLog.write("probe start arguments=\(arguments.joined(separator: " ")) accessibilityTrusted=\(AXIsProcessTrusted())")
        guard AXIsProcessTrusted() else {
            ProbeLog.write("Accessibility is not granted to this build; grant it and run again")
            return
        }
        let seconds = arguments.count > 1 ? Double(arguments[1]) ?? 0 : 0
        switch arguments.first {
        case "windows": await windows(seconds: seconds)
        case "apply": await apply(Array(arguments.dropFirst()))
        case "displays": await displays()
        case "displays-watch": await displaysWatch(seconds: seconds)
        case "tiling": await tiling(seconds: seconds)
        case "keys": await keys(seconds: seconds)
        case "raise": await raise(Array(arguments.dropFirst()))
        default: ProbeLog.write("unknown subcommand; use windows|apply|raise|displays|displays-watch|tiling|keys")
        }
    }

    // MARK: windows

    private static func windows(seconds: Double) async {
        ProbeLog.write("_AXUIElementGetWindow available=\(WindowIDResolver.privateSymbolAvailable)")
        let apps = observableApps()
        let everything = WindowIDResolver.windowList(all: true)
        let onScreen = WindowIDResolver.windowList()
        for app in apps {
            let pid = app.processIdentifier
            let bundle = app.bundleIdentifier ?? "?"
            let rows = await queue.run(pid: pid) { describeWindows(pid: pid) }
            let cgAll = everything.filter { $0.pid == pid && $0.layer == 0 }
            let cgOnScreen = onScreen.filter { $0.pid == pid && $0.layer == 0 }
            guard !rows.isEmpty || !cgAll.isEmpty else { continue }
            ProbeLog.write(
                "app bundle=\(bundle) pid=\(pid) axWindows=\(rows.count) "
                    + "cgWindowsAll=\(cgAll.count) cgIdsAll=\(cgAll.map { String($0.id) }.joined(separator: ",")) "
                    + "cgWindowsOnScreen=\(cgOnScreen.count) cgIdsOnScreen=\(cgOnScreen.map { String($0.id) }.joined(separator: ","))")
            for row in rows { ProbeLog.write("  window bundle=\(bundle) \(row.text)", title: row.title) }
        }
        await observe(apps: apps, seconds: seconds, include: { _ in true })
    }

    private struct WindowRow: Sendable {
        let text: String
        let title: String?
    }

    /// Minimized and full screen are what Tafl's window read decides; nil when the app did not answer.
    private nonisolated static func describeWindows(pid: pid_t) -> [WindowRow] {
        let ask = WindowQueries27.live
        return AXWindowAccess.windows(of: pid).map { window in
            let frame = AXWindowAccess.frame(window)
            let frameText = format(frame)
            let identityText: String
            if case .success(let rect) = frame, let (id, by) = WindowIDResolver.windowID(window, pid: pid, frame: rect) {
                identityText = "windowID=\(id) resolvedBy=\(by)"
            } else {
                identityText = "windowID=none"
            }
            let minimized = try? ask.isMinimized(window: ask.windowElement(of: window))
            let text = "frame=\(frameText) position-settable=\(AXWindowAccess.isSettable(window, attribute: "AXPosition")) "
                + "size-settable=\(AXWindowAccess.isSettable(window, attribute: "AXSize")) "
                + "minimized=\(describe(minimized)) fullscreen=\(describe(try? ask.fullscreen(of: window).get())) "
                + "axFullScreenAttribute=\(describe(try? ask.bool(window, "AXFullScreen").get())) "
                + "subrole=\(AXWindowAccess.subrole(window) ?? "nil") \(identityText)"
            return WindowRow(text: text, title: AXWindowAccess.title(window))
        }
    }

    // MARK: apply

    private static func apply(_ arguments: [String]) async {
        let numbers = arguments.prefix(4).compactMap { Double($0) }
        guard numbers.count == 4 else {
            ProbeLog.write("usage: apply <x> <y> <w> <h> [size-first|position-first] [keep-enhanced-ui]")
            return
        }
        let target = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
        let positionFirst = arguments.contains("position-first")
        let keepEnhancedUI = arguments.contains("keep-enhanced-ui")
        await panel.pause(
            "Focus the window to move, then press Continue.\nTarget (Accessibility coordinates) \(format(target)), "
                + "\(positionFirst ? "position first" : "size first"), Enhanced UI \(keepEnhancedUI ? "kept" : "switched off").")
        guard let app = NSWorkspace.shared.frontmostApplication else {
            ProbeLog.write("no frontmost application")
            return
        }
        let pid = app.processIdentifier
        guard pid != ProcessInfo.processInfo.processIdentifier else {
            ProbeLog.write("apply refused: Tafl itself is frontmost; focus the window under test before pressing Continue")
            return
        }
        ProbeLog.write("apply bundle=\(app.bundleIdentifier ?? "?") pid=\(pid) target=\(format(target)) "
            + "order=\(positionFirst ? "position-first" : "size-first") keepEnhancedUI=\(keepEnhancedUI)")
        await queue.run(pid: pid) {
            applySequence(pid: pid, target: target, positionFirst: positionFirst, keepEnhancedUI: keepEnhancedUI)
        }
    }

    private enum Part { case size, position }

    private nonisolated static func applySequence(pid: pid_t, target: CGRect, positionFirst: Bool, keepEnhancedUI: Bool) {
        guard let window = AXWindowAccess.focusedWindow(of: pid) else {
            ProbeLog.write("apply: no focused window")
            return
        }
        let enhancedBefore = AXWindowAccess.enhancedUserInterface(app: pid)
        let minimum = try? WindowQueries27.live.minimumSize(of: window)
        ProbeLog.write("apply: enhancedUI=\(describe(enhancedBefore)) minimumSize=\(minimum.map { "\($0.width)x\($0.height)" } ?? "nil") "
            + "position-settable=\(AXWindowAccess.isSettable(window, attribute: "AXPosition")) "
            + "size-settable=\(AXWindowAccess.isSettable(window, attribute: "AXSize"))")
        var restoreEnhancedUI = false
        if !keepEnhancedUI, enhancedBefore == true {
            ProbeLog.write("apply: switching Enhanced UI off, status=\(AXWindowAccess.setEnhancedUserInterface(app: pid, false).rawValue)")
            restoreEnhancedUI = true
        }
        let (initial, initialReadMs) = timed { AXWindowAccess.frame(window) }
        ProbeLog.write("apply: initial frame=\(format(initial)) readMs=\(ms(initialReadMs))")
        var previous = try? initial.get()
        let parts: [Part] = positionFirst ? [.position, .size] : [.size, .position, .size]
        for (index, part) in parts.enumerated() {
            let (status, writeMs) = timed {
                switch part {
                case .size: AXWindowAccess.setSize(window, target.size)
                case .position: AXWindowAccess.setPosition(window, target.origin)
                }
            }
            let (readBack, readMs) = timed { AXWindowAccess.frame(window) }
            var line = "apply: step=\(index + 1) wrote=\(part) status=\(status.rawValue) writeMs=\(ms(writeMs)) readMs=\(ms(readMs)) frame=\(format(readBack))"
            if let previous, let now = try? readBack.get() {
                switch part {
                case .size where now.origin != previous.origin:
                    line += " CHANGED-UNWRITTEN origin \(format(previous.origin)) -> \(format(now.origin))"
                case .position where now.size != previous.size:
                    line += " CHANGED-UNWRITTEN size \(format(previous.size)) -> \(format(now.size))"
                default: break
                }
            }
            ProbeLog.write(line)
            previous = (try? readBack.get()) ?? previous
        }
        usleep(25_000)
        let settled = AXWindowAccess.frame(window)
        var line = "apply: after25ms frame=\(format(settled))"
        if let before = previous, let after = try? settled.get() {
            line += before == after ? " unchangedFromLastReadBack" : " CHANGED-BY-REAPPLY-WINDOW from \(format(before)) to \(format(after))"
            line += " shortfall=\(format(target.width - after.width, target.height - after.height)) offset=\(format(after.origin.x - target.origin.x, after.origin.y - target.origin.y))"
        }
        ProbeLog.write(line)
        if restoreEnhancedUI {
            ProbeLog.write("apply: restoring Enhanced UI, status=\(AXWindowAccess.setEnhancedUserInterface(app: pid, true).rawValue)")
        }
    }

    // MARK: raise

    /// Raises the first window of each app, in the order given, as the platform does (`Raise27`:
    /// raise, frontmost write, then the activation fallback), then waits up to 1 s for the last app
    /// to become frontmost, as activation is asynchronous, and logs the window server's order (front
    /// to back): the last app should be in front and frontmost.
    private static func raise(_ bundleIDs: [String]) async {
        guard !bundleIDs.isEmpty else {
            ProbeLog.write("usage: raise <bundle-id> [<bundle-id> ...]  (the last one ends on top)")
            return
        }
        var raised: Set<pid_t> = []
        var last: (bundleID: String, pid: pid_t)?
        for bundleID in bundleIDs {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
                ProbeLog.write("raise: \(bundleID) is not running")
                continue
            }
            let pid = app.processIdentifier
            let outcome = await queue.run(pid: pid) { () -> Raise27.Outcome? in
                guard let window = AXWindowAccess.windows(of: pid).first else { return nil }
                return Raise27.bringForward(
                    admit: { true },
                    raise: { AXWindowAccess.raise(window) },
                    makeFrontmost: { AXWindowAccess.setFrontmost(app: pid) })
            }
            let outcomeText = switch outcome {
            case nil: "no window"
            case .failed(let code)?: "failed(\(code.rawValue))"
            case let other?: "\(other)"
            }
            var line = "raise: bundle=\(bundleID) pid=\(pid) outcome=\(outcomeText)"
            if outcome == .raisedWithoutFrontmost {
                let activated = Raise27.activate(pid: pid, admit: { true })
                line += " activated=\(activated)"
            }
            ProbeLog.write(line)
            guard outcome == .raised || outcome == .raisedWithoutFrontmost else { continue }
            raised.insert(pid)
            last = (bundleID, pid)
        }
        var waited = 0
        while let last, NSWorkspace.shared.frontmostApplication?.processIdentifier != last.pid, waited < 1000 {
            try? await SuspendingClock().sleep(for: .milliseconds(50))
            waited += 50
        }
        let order = WindowIDResolver.windowList().filter { $0.layer == 0 && raised.contains($0.pid) }
        ProbeLog.write("raise: front to back \(order.map { "pid=\($0.pid) id=\($0.id)" }.joined(separator: ", "))")
        let frontmost = NSWorkspace.shared.frontmostApplication
        let matched = last.map { frontmost?.processIdentifier == $0.pid } ?? false
        ProbeLog.write(
            "raise: frontmost=\(frontmost?.bundleIdentifier ?? "nil") expected=\(last?.bundleID ?? "nil") matched=\(matched) after \(waited) ms")
    }

    // MARK: displays

    private static func displays() async {
        await displaySnapshot(label: "displays-first")
        await panel.pause("Change the Dock (auto-hide on or off, or move it), then press Continue.")
        await displaySnapshot(label: "displays-second")
    }

    private static func displaySnapshot(label: String) async {
        logDisplays(label: label)
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            ProbeLog.write("\(label): dock not running")
            return
        }
        let dockFrame = await queue.run(pid: dock.processIdentifier) { dockListFrame(pid: dock.processIdentifier) }
        ProbeLog.write(
            "\(label): dock axListFrame=\(dockFrame) orientation=\(preference("orientation", "com.apple.dock")) "
                + "autohide=\(preference("autohide", "com.apple.dock")) tilesize=\(preference("tilesize", "com.apple.dock"))")
    }

    private static func logDisplays(label: String) {
        let displays = DisplayReader27.displays()
        ProbeLog.write("\(label): count=\(displays.count)")
        for display in displays {
            let frame = display.frame.rect, visible = display.visibleFrame.rect
            ProbeLog.write(
                "\(label): id=\(display.displayID) name=\(display.name) vendor=\(display.vendor) model=\(display.model) "
                    + "serial=\(display.serial) identifier=\(display.vendor)-\(display.model)-\(display.serial) "
                    + "builtin=\(CGDisplayIsBuiltin(display.displayID) != 0) frameAX=\(format(frame)) visibleAX=\(format(visible)) "
                    + "insets(l,t,r,b)=\(format(visible.minX - frame.minX, visible.minY - frame.minY, frame.maxX - visible.maxX, frame.maxY - visible.maxY)) "
                    + "safeAreaTop=\(display.safeAreaTop)")
        }
    }

    private nonisolated static func dockListFrame(pid: pid_t) -> String {
        let app = AXUIElementCreateApplication(pid)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement]
        else { return "no children" }
        let lists = children.filter { child in
            var role: AnyObject?
            return AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role) == .success
                && (role as? String) == kAXListRole
        }
        return lists.isEmpty ? "no list" : lists.map { format(AXWindowAccess.frame($0)) }.joined(separator: ",")
    }

    // MARK: displays-watch

    private static func displaysWatch(seconds: Double) async {
        logDisplays(label: "displays-initial")
        let monitor = ReconfigurationMonitor27 { phase, detail in
            let at = ProbeLog.now()
            ProbeLog.write(
                "reconfiguration \(phase) displayID=\(detail.displayID) flags=0x\(String(detail.flags, radix: 16)) [\(flagNames(detail.flags))]",
                at: at)
            if phase == .ended { Task { @MainActor in logDisplays(label: "displays-after-ended") } }
        }
        let screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in
            ProbeLog.write("didChangeScreenParameters", at: ProbeLog.now())
        }
        await observe(apps: observableApps(), seconds: seconds, include: { $0 == kAXWindowMovedNotification || $0 == kAXWindowResizedNotification })
        NotificationCenter.default.removeObserver(screenObserver)
        monitor.invalidate()
    }

    private nonisolated static func flagNames(_ raw: UInt32) -> String {
        let flags = CGDisplayChangeSummaryFlags(rawValue: raw)
        let names: [(CGDisplayChangeSummaryFlags, String)] = [
            (.beginConfigurationFlag, "begin"), (.movedFlag, "moved"), (.setMainFlag, "setMain"),
            (.setModeFlag, "setMode"), (.addFlag, "add"), (.removeFlag, "remove"),
            (.enabledFlag, "enabled"), (.disabledFlag, "disabled"), (.mirrorFlag, "mirror"),
            (.unMirrorFlag, "unMirror"), (.desktopShapeChangedFlag, "desktopShapeChanged"),
        ]
        return names.filter { flags.contains($0.0) }.map(\.1).joined(separator: ",")
    }

    // MARK: tiling

    private static func tiling(seconds: Double) async {
        for key in ["EnableTilingByEdgeDrag", "EnableTilingOptionAccelerator", "EnableTopTilingByEdgeDrag", "EnableTiledWindowMargins"] {
            ProbeLog.write("com.apple.WindowManager \(key)=\(preference(key, "com.apple.WindowManager"))")
        }
        let displays = DisplayReader27.displays()
        await observe(
            apps: observableApps(), seconds: seconds,
            include: { $0 == kAXWindowMovedNotification || $0 == kAXWindowResizedNotification },
            annotate: { frame in tilingAnnotation(frame: frame, displays: displays) })
    }

    private nonisolated static func tilingAnnotation(frame: CGRect, displays: [RawDisplay27]) -> String {
        guard let display = displays.max(by: { area($0.frame.rect.intersection(frame)) < area($1.frame.rect.intersection(frame)) }) else {
            return "no display"
        }
        let visible = display.visibleFrame.rect
        let halfW = visible.width / 2, halfH = visible.height / 2
        let candidates: [(String, CGRect)] = [
            ("fill", visible),
            ("left-half", CGRect(x: visible.minX, y: visible.minY, width: halfW, height: visible.height)),
            ("right-half", CGRect(x: visible.minX + halfW, y: visible.minY, width: halfW, height: visible.height)),
            ("top-half", CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: halfH)),
            ("bottom-half", CGRect(x: visible.minX, y: visible.minY + halfH, width: visible.width, height: halfH)),
            ("top-left", CGRect(x: visible.minX, y: visible.minY, width: halfW, height: halfH)),
            ("top-right", CGRect(x: visible.minX + halfW, y: visible.minY, width: halfW, height: halfH)),
            ("bottom-left", CGRect(x: visible.minX, y: visible.minY + halfH, width: halfW, height: halfH)),
            ("bottom-right", CGRect(x: visible.minX + halfW, y: visible.minY + halfH, width: halfW, height: halfH)),
        ]
        let deltas = candidates.map { name, rect in
            (name, max(abs(rect.minX - frame.minX), abs(rect.minY - frame.minY), abs(rect.width - frame.width), abs(rect.height - frame.height)))
        }
        let nearest = deltas.min { $0.1 < $1.1 }!
        return "display=\(display.displayID) visibleAX=\(format(visible)) nearest=\(nearest.0) maxDelta=\(String(format: "%.2f", nearest.1))"
    }

    private nonisolated static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }

    // MARK: keys

    private struct Chord {
        let name: String
        let keyCode: Int
        let modifiers: Int
    }

    private static let defaultChords: [Chord] = {
        let ctrlOpt = controlKey | optionKey
        let ctrlOptCmd = ctrlOpt | cmdKey
        return [
            Chord(name: "left-half", keyCode: kVK_LeftArrow, modifiers: ctrlOpt),
            Chord(name: "right-half", keyCode: kVK_RightArrow, modifiers: ctrlOpt),
            Chord(name: "top-half", keyCode: kVK_UpArrow, modifiers: ctrlOpt),
            Chord(name: "bottom-half", keyCode: kVK_DownArrow, modifiers: ctrlOpt),
            Chord(name: "top-left", keyCode: kVK_ANSI_U, modifiers: ctrlOpt),
            Chord(name: "top-right", keyCode: kVK_ANSI_I, modifiers: ctrlOpt),
            Chord(name: "bottom-left", keyCode: kVK_ANSI_J, modifiers: ctrlOpt),
            Chord(name: "bottom-right", keyCode: kVK_ANSI_K, modifiers: ctrlOpt),
            Chord(name: "first-third", keyCode: kVK_ANSI_D, modifiers: ctrlOpt),
            Chord(name: "center-third", keyCode: kVK_ANSI_F, modifiers: ctrlOpt),
            Chord(name: "last-third", keyCode: kVK_ANSI_G, modifiers: ctrlOpt),
            Chord(name: "first-two-thirds", keyCode: kVK_ANSI_E, modifiers: ctrlOpt),
            Chord(name: "center-two-thirds", keyCode: kVK_ANSI_R, modifiers: ctrlOpt),
            Chord(name: "last-two-thirds", keyCode: kVK_ANSI_T, modifiers: ctrlOpt),
            Chord(name: "maximize", keyCode: kVK_Return, modifiers: ctrlOpt),
            Chord(name: "maximize-height", keyCode: kVK_UpArrow, modifiers: ctrlOpt | shiftKey),
            Chord(name: "center", keyCode: kVK_ANSI_C, modifiers: ctrlOpt),
            Chord(name: "restore", keyCode: kVK_Delete, modifiers: ctrlOpt),
            Chord(name: "larger", keyCode: kVK_ANSI_Equal, modifiers: ctrlOpt),
            Chord(name: "smaller", keyCode: kVK_ANSI_Minus, modifiers: ctrlOpt),
            Chord(name: "display-left", keyCode: kVK_LeftArrow, modifiers: ctrlOptCmd),
            Chord(name: "display-right", keyCode: kVK_RightArrow, modifiers: ctrlOptCmd),
            Chord(name: "display-up", keyCode: kVK_UpArrow, modifiers: ctrlOptCmd),
            Chord(name: "display-down", keyCode: kVK_DownArrow, modifiers: ctrlOptCmd),
            Chord(name: "display-under-pointer", keyCode: kVK_ANSI_M, modifiers: ctrlOptCmd),
        ]
    }()

    private static func keys(seconds: Double) async {
        logLayout(label: "layout")
        let hotkeys = CarbonHotkeys()
        ProbeLog.write("carbon event handler install status=\(hotkeys.installStatus)")
        hotkeys.onPress = { id in
            ProbeLog.write("hotkey pressed id=\(id) chord=\(defaultChords[Int(id) - 1].name)")
        }
        // Each chord both ways; the exclusive registration stays for the presses.
        for (index, chord) in defaultChords.enumerated() {
            let id = UInt32(index + 1)
            let keyCode = UInt32(chord.keyCode)
            let modifiers = UInt32(chord.modifiers)
            let shared = hotkeys.register(keyCode: keyCode, modifiers: modifiers, id: id, exclusive: false)
            hotkeys.unregister(id: id)
            let exclusive = hotkeys.register(keyCode: keyCode, modifiers: modifiers, id: id, exclusive: true)
            ProbeLog.write(
                "register chord=\(chord.name) keyCode=\(chord.keyCode) modifiers=\(chord.modifiers)"
                    + " nonexclusive=\(shared) \(describe(status: shared)) exclusive=\(exclusive) \(describe(status: exclusive))")
        }
        let token = KeyboardLayoutReader27.observeChanges {
            Task { @MainActor in
                ProbeLog.write("input source changed")
                logLayout(label: "layout-after-change")
            }
        }
        await pause(seconds: seconds)
        DistributedNotificationCenter.default().removeObserver(token)
        for index in defaultChords.indices { hotkeys.unregister(id: UInt32(index + 1)) }
    }

    private static func logLayout(label: String) {
        ProbeLog.write("\(label): inputSource=\(currentInputSourceID())")
        let layout = KeyboardLayoutReader27.currentLayout()
        for code in Set(defaultChords.map { UInt16($0.keyCode) }).sorted() {
            let entry = layout[code]
            ProbeLog.write("\(label): keyCode=\(code) plain=\(quoted(entry?.plain)) shifted=\(quoted(entry?.shifted))")
        }
    }

    private static func currentInputSourceID() -> String {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        else { return "unknown" }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private static func describe(status: OSStatus) -> String {
        switch Int(status) {
        case 0: "ok"
        case eventHotKeyExistsErr: "eventHotKeyExistsErr"
        case eventHotKeyInvalidErr: "eventHotKeyInvalidErr"
        default: "other"
        }
    }

    // MARK: shared

    private static func observableApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy != .prohibited && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
    }

    /// Waits on the suspending clock, so the time the Mac sleeps does not count.
    private static func pause(seconds: Double) async {
        try? await SuspendingClock().sleep(for: .seconds(seconds))
    }

    /// Observes every app for `seconds`, logging each notification that `include` accepts with
    /// the frame read while handling it. Registration failures are logged too. The callback only
    /// takes the stamp and queues the reads on the app's own queue, so an app that is slow to
    /// answer delays neither another app's callbacks nor their stamps.
    private static func observe(
        apps: [NSRunningApplication], seconds: Double,
        include: @escaping @Sendable (String) -> Bool,
        annotate: (@Sendable (CGRect) -> String)? = nil
    ) async {
        let hub = AXObserverHub()
        let queue = queue
        for app in apps {
            let pid = app.processIdentifier
            let bundleID = app.bundleIdentifier
            let failed = await queue.run(pid: pid) {
                hub.observe(pid: pid, bundleID: bundleID) { event in
                    let at = ProbeLog.now()
                    guard include(event.notification) else { return }
                    queue.enqueue(pid: event.pid) {
                        let frame = AXWindowAccess.frame(event.element)
                        var line = "event bundle=\(event.bundleID ?? "?") pid=\(event.pid) notification=\(event.notification) frame=\(format(frame))"
                        if let annotate, let rect = try? frame.get() { line += " " + annotate(rect) }
                        let title = event.notification == kAXTitleChangedNotification ? AXWindowAccess.title(event.element) : nil
                        ProbeLog.write(line, title: title, at: at)
                    }
                }
            }
            if !failed.isEmpty {
                ProbeLog.write("registration failed bundle=\(bundleID ?? "?") pid=\(pid) notifications=\(failed.keys.sorted().joined(separator: ","))")
            }
        }
        ProbeLog.write("observing \(apps.count) apps for \(seconds) s")
        await pause(seconds: seconds)
        hub.stopAll()
    }

    private nonisolated static func timed<T>(_ body: () -> T) -> (T, Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        let value = body()
        return (value, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }

    private nonisolated static func ms(_ value: Double) -> String { String(format: "%.3f", value) }

    private nonisolated static func preference(_ key: String, _ domain: String) -> String {
        CFPreferencesCopyAppValue(key as CFString, domain as CFString).map { "\($0)" } ?? "unset"
    }

    private nonisolated static func describe(_ value: Bool?) -> String { value.map { "\($0)" } ?? "nil" }
    private nonisolated static func quoted(_ value: String?) -> String {
        guard let value else { return "nil" }
        let scalars = value.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
        return "\"\(value)\"[\(scalars)]"
    }

    private nonisolated static func format(_ rect: CGRect) -> String {
        rect.isNull ? "null" : format(rect.minX, rect.minY, rect.width, rect.height)
    }

    private nonisolated static func format(_ point: CGPoint) -> String { format(point.x, point.y) }
    private nonisolated static func format(_ size: CGSize) -> String { format(size.width, size.height) }

    private nonisolated static func format(_ result: Result<CGRect, AXFailure>) -> String {
        switch result {
        case .success(let rect): format(rect)
        case .failure(let failure): "error\(failure.code.rawValue)"
        }
    }

    private nonisolated static func format(_ values: CGFloat...) -> String {
        "(" + values.map { String(format: "%.1f", Double($0)) }.joined(separator: ", ") + ")"
    }
}

/// Probe output: every line carries a monotonic timestamp, and window titles are `.private`.
nonisolated enum ProbeLog {
    private static let origin = DispatchTime.now().uptimeNanoseconds

    static func start() { _ = origin }

    /// A monotonic stamp (uptime, which does not advance while the Mac sleeps). Take it first in a callback.
    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    static func write(_ message: String, title: String? = nil, at: UInt64? = nil) {
        let stamp = String(format: "%.3f", Double((at ?? now()) &- origin) / 1_000_000)
        if let title {
            PlatformLog.probe.notice("[\(stamp, privacy: .public) ms] \(message, privacy: .public) title=\(title, privacy: .private)")
        } else {
            PlatformLog.probe.notice("[\(stamp, privacy: .public) ms] \(message, privacy: .public)")
        }
    }
}
#endif
