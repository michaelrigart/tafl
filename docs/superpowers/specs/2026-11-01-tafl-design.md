# Tafl: design

**Date:** 2026-11-01
**Owner:** Michael Rigart
**Status:** In progress (branch `feat/tafl-v1`, pull request
[michaelrigart/tafl#2](https://github.com/michaelrigart/tafl/pull/2)). Signed off by Michael on
2026-11-01, after Codex's spec review.
**Name:** Tafl, after the Norse board game played by placing pieces on a grid.
**Revised:** 2026-11-06: signing moved to Michael's Personal Team; see
`docs/superpowers/specs/2026-11-06-tafl-distribution-design.md`;
2026-11-10: how Tafl notices the Accessibility switch;
2026-11-10: measured on macOS 27.2 (feasibility probe);
2026-11-10: a layout you apply brings its windows to the front.

## Why

Michael uses Rectangle (`rxhanson/Rectangle`, MIT) to place windows from the keyboard. He
mostly uses halves today, but wants more:

- **Multiple displays.** He works on one external ultrawide display in clamshell mode, on
  the built-in display, and sometimes on two displays at once.
- **A configuration file in his dotfiles**, as the single source of truth.
- **Layouts** defined in that file that restore automatically.
- **Everything from the keyboard.**

Rectangle is maintained and healthy, so this is not a replacement for a dead project.
Rectangle's settings live in `defaults`, and 73 of its 117 settings exist only as hidden
`defaults write` switches. Layouts are reserved for the closed-source Rectangle Pro, where
they are the most-reported weak point. Rectangle's author wrote on 2026-10-15 (PR #1903)
that its central `WindowManager` is "a flaw in my design": all logic flows through a few
central files and changes accumulate there. He plans to rebuild it as a pipeline with
hooks.

Tafl is the fourth app in Michael's Mac suite, after Muninn, Linger and Hulder. It does a
few things reliably, is polished from the first release, and its codebase stays high
quality when macOS changes.

## What the Rectangle review taught us

Reviewed on 2026-10-31: Rectangle 2.0.4's source, its 765 issues, 540 discussions and 430
pull requests, Rectangle Pro's public feature list, and the competing tools.

- **Hard-won knowledge lives in small functions.**
  - Rectangle is about 28k lines of app code and 10.8k lines of tests.
  - Most of the code serves breadth Tafl doesn't need: 143 actions, 84 classes that each
    compute one fixed grid cell, about 6k lines of experimental animation and resizing,
    and global settings read inside the window math (about 600 references).
  - The knowledge worth keeping fits in about 25 small, mostly pure functions and about 10
    techniques at the macOS boundary (see "Reuse from Rectangle").
- **The Accessibility layer causes most bugs.** About 500 bug reports cluster around:
  - apps that stop answering Accessibility calls (Electron, Chromium, Teams);
  - permission that goes stale after macOS updates;
  - window ids lost after wake;
  - stale screen geometry after Dock or display changes.
- **macOS 26 and 27 regressions** reported against Rectangle:
  - drag-to-snap stops working after 26.2 (#1692);
  - the auto-hidden Dock's space is still reserved on 27 (#1922);
  - "Failed to find frontmost window" with a second instance of an app (#1860);
  - a fullscreen window on one display blocks actions on the others (#1260).
- **What users ask for and don't get** from free Rectangle:
  - layouts per display setup, restored on dock and undock;
  - moving a window to a specific display, or to the one under the pointer;
  - a real interface for the hidden settings.
- **No public API for Spaces.** Spaces control broke on macOS 27 in yabai and Hammerspoon.
- **macOS's own tiling** (since macOS 15) covers dragging to edges and corners. It has no
  thirds, no custom sizes, no cross-display moves and no saved layouts. Every tool tells
  users to switch one of the two off.

## What macOS allows

These are facts from Rectangle's source and documentation and from Apple's documentation.
**None was verified on macOS 27.2 when this spec was signed off.** The plan's first task
checked the ones Tafl depends on (see Delivery); "Measured on macOS 27.2" records the result.

- **Windows are controlled through Accessibility** (`AXUIElement`): read and set position
  and size, check whether each is settable, raise. This needs the Accessibility
  permission and no other.
  - An application element can deliver window created, moved, resized, title changed and
    destroyed notifications through an `AXObserver`. Registering for one can fail.
  - An app can take a long time to answer, or never answer. Each call needs a timeout.
  - Chromium and Electron apps slow down or ignore resizes while `AXEnhancedUserInterface`
    is on. Rectangle switches it off around each write, except when VoiceOver or Switch
    Control is running.
- **Setting a frame is two operations.** macOS clamps a window's size to the display it is
  currently on, so the order of size and position matters, and the result must be read
  back. Rectangle sets size first when crossing displays, reads back what was accepted,
  positions, retries a size once, and reapplies once more 25 ms later after a
  cross-display move.
- **Window identity** needs the private `_AXUIElementGetWindow`, with fallbacks (matching
  the window list by process and frame). It is the only private symbol Rectangle uses.
- **The Accessibility window list probably covers only the current Space.** To verify.
- **Screen geometry:**
  - `NSScreen.visibleFrame` goes stale after the Dock changes. Rectangle corrects it by
    reading the Dock's Accessibility frame.
  - Notched displays need a separate top inset.
  - Accessibility uses top-left coordinates, AppKit uses bottom-left coordinates.
- **Display changes:**
  - macOS reports display reconfiguration (begin and end) through
    `CGDisplayRegisterReconfigurationCallback`.
  - Rectangle's author says macOS gives no notice before a display disconnects. Whether
    the begin callback arrives before macOS moves the windows is unknown.
  - macOS moves windows off a removed display on its own. It may also restore positions
    when a known display returns. To verify on 27.2.
- **macOS tiling settings** are readable in the `com.apple.WindowManager` preferences:
  `EnableTilingByEdgeDrag`, `EnableTilingOptionAccelerator`,
  `EnableTopTilingByEdgeDrag`, `EnableTiledWindowMargins`.
- **Global hotkeys** work through Carbon's `RegisterEventHotKey` without any permission or
  event tap.

## Measured on macOS 27.2

The feasibility probe ran on 2026-11-05 and 2026-11-10, on the built-in display alone and
docked to a 21:9 ultrawide. No stop rule triggered: windows read and move reliably; the one
change to the part Tafl didn't write is exact and computable; the begin callback arrives
before macOS moves any window; macOS's own restore matches rule 2 stepping aside; and macOS's
moves end within 0.5 s of the end callback.

- **The named macOS adjustment.** A position write that moves a window onto a display whose
  visible frame is shorter than the window clamps its height: 1410 became 1130, in 5 of 5
  apps. All five clamps landed at the visible top (y 39), where "the height that ends at the
  destination's visible bottom" and "the destination's visible height" agree. Tafl's
  adjustment uses the bottom form; that form for a window below the visible top, and a width
  clamp (a width wider than the destination's visible frame becoming its visible width), were
  not observed and are inferred. Moving onto a taller display never changed the size. A size
  write is clamped by the app at the window's current origin, to the bottom of the display it
  is on; that is the written part, and size-position-size recovers it. Cross-display and
  single-display runs ended on the target frame (shortfall 0) except the 1 pt below, Zen with
  Enhanced UI left on (900 pt off in 3 of 3 runs, see Enhanced UI) and a target at y 0, which
  ended 39 pt lower because macOS keeps windows below the menu bar; Tafl never targets above
  the visible frame.
- **Reapply.** Nothing changed 25 ms after the last read-back in 45 of 45 runs, on one display
  and across displays. On 27.2 there is no reapply (`reapplyDelay` is nil); the mechanism stays
  for a later macOS.
- **Size shortfall.** At most 1 pt (TextEdit and an Electron app, Dock visible). A terminal's
  cell rounding reads 2 pt off when tiled.
- **Quiet period.** macOS's moves ended 70 to 400 ms after the end callback, never later than
  0.5 s. The quiet period stays 1.5 s for margin; the 3 s cap is not near.
- **Recognition tolerance.** 2 pt. macOS's tiles match Rectangle's gap rule exactly. With
  tiling margins on they are recognised only when `gap` is 8.
- **Space coverage.** Accessibility lists only the current Space's windows. Minimized windows
  are listed.
- **Dock.** The auto-hidden Dock reserves nothing. `visibleFrame` was current a few seconds
  after a Dock change, so no correction beyond reading the visible frame is needed at that
  latency; the Dock reader stays. The Dock sits on the main display: the built-in when docked,
  the external alone with the lid closed.
- **A taken shortcut does not show up.** An exclusive registration succeeds silently while
  another app (Rectangle) holds the chord, and Tafl takes every press (45 of 45). Tafl cannot
  detect it. The README tells users to quit Rectangle.
- **Display identity.** Name, vendor, model and serial were stable across reconnect, lid
  close and open, wake and reboot. The CoreGraphics display id changed across a reboot (3 to
  2), so Tafl never keys on it.
- **macOS restores windows itself** to their per-setup frames when a known setup returns
  (replug, lid, wake), within about 100 ms.
- **Wake.** For about 2 s around wake, Accessibility reads of live windows fail with -25202
  (invalid element). So only a window's destroyed notification and its app's quit end a
  window; a read that finds the element invalid fails that read only and keeps the
  registration. An app that fails to register in that window is tried again (see "After wake
  or a user switch"). A DarkWake shows a placeholder display (no name, "unkn" and "virt",
  1920 x 1080) for about 1.3 s, shorter than the 1.5 s quiet period. One that lasted longer
  would settle as a new setup, so Tafl never settles on a setup that holds one (see "Display
  changes"). Known limit: a real display that reports no name with vendor "unkn" and model
  "virt" would look like the placeholder, and Tafl would never settle on a setup that holds it.
  Known limit: if Tafl quits while no display is connected and starts again with one, it
  treats that display as a first setup, because the saved memory cannot tell "no displays"
  from "nothing remembered".
- **Enhanced UI.** Switching it off returns -25208 in a Gecko browser, yet it works. Tafl
  always attempts it and ignores the status. Skipping the switch failed in 3 of 3 runs in Zen
  (the position write reverted the size, and the frame ended 900 pt off), which is why Tafl
  always attempts it.
- **Timing.** Reads take 0.06 to 0.7 ms (up to 168 ms right after a cross-display write, and
  22 to 36 ms right after a size write on a single display); writes take 0.1 to 38 ms.

## Success

- Tafl replaces Rectangle on Michael's Mac and runs from login for weeks without attention.
- Every shortcut Michael uses in Rectangle today works the same way in Tafl, with the same
  keys.
- Docking, undocking and connecting a second display leave the visible windows where the
  rules in "Display changes" say, without any action from Michael. Waking from sleep
  moves nothing.
- A changed config file (for example after `chezmoi apply`) takes effect within a second,
  without a restart. A broken file never breaks the running app.
- A window lands at its final frame in one step, with no visible correction, except for
  apps that refuse the size.
- No measurable CPU use while idle.
- When macOS 28 changes something, the fix lives in the platform layer only.

## Goals (v1)

1. **Placements from the keyboard:** halves, quarters, thirds, two-thirds, maximize,
   maximize height, center, restore, larger and smaller. The full list is in "Actions".
2. **Display moves from the keyboard:** to the display on the left, right, above or below,
   and to the display under the pointer. A window keeps its placement when it moves.
3. **Repeat behaviour:** repeating a half moves the window to the next display in that
   direction, as Michael's Rectangle does today. Configurable.
4. **Display changes** handled by fixed rules (see "Display changes").
5. **Layouts** defined in the config file. A layout applies automatically when its display
   setup connects, or by its own shortcut. While it is active, new windows of its apps go
   to their place.
6. **A config file** as the single source of truth, reloaded live.
7. **A Settings window** that shows the configuration in plain language but never edits it.
   It can capture the current arrangement as a layout snippet.
8. **Housekeeping:** launch at login, a menu bar icon and no Dock icon, an Accessibility
   onboarding, and logging.

## Non-goals (v1)

Each of these can come later if it fits the architecture below.

- **Spaces** (Michael's decision): no moving windows between Spaces, no per-Space layouts.
- **Tafl's own drag-to-snap.** Dragging is left to macOS's tiling (see "Dragging"). A drag
  input can be added later as one more input to the pipeline.
- **Editing settings in the interface.** The config file is the only place to change them.
- **Other window-manager features:**
  - animation, gestures, throw, stash, pin or Todo mode;
  - automatic tiling, and focus switching as a feature of its own (a layout you apply
    brings its windows to the front; see "Layouts");
  - nudge, width-only or height-only resize;
  - custom grids beyond the named placements;
  - per-app rules outside layouts;
  - launching apps from a layout, or session restore;
  - a URL scheme, command-line tool, AppleScript or Shortcuts.
- **Stage Manager awareness.** If it is on, Tafl ignores the strip.
- **Distribution:** automatic updates, localisation (English only), and the Mac App Store.
- **macOS 26 and earlier.**

## Anti-goals

Tafl has failed, even if it works, if it:

- writes to the config file, apart from creating a starter file when none exists and
  Michael asks for one;
- has any setting that exists only as a hidden flag. Every setting is in the config file
  and shown in Settings;
- moves a window nobody asked it to move. The only triggers are a shortcut or menu action,
  a layout trigger, a new window while a layout is active, and a display change;
- moves a window back after the user, or macOS, moved it;
- fights apps or macOS with repair loops. A failed placement is retried within the bounded
  sequence in "Applying a frame", then reported, and left alone;
- fails silently, or with an unexplained beep. Every failed action says why;
- blocks the main thread on an Accessibility call, or hangs when an app doesn't answer;
- installs an event tap or posts synthetic input;
- uses private API outside the platform layer, or crashes when a private symbol is missing;
- writes Apple's preferences, including `com.apple.WindowManager`;
- launches apps;
- asks for any permission other than Accessibility;
- makes any network connection, or collects telemetry;
- shows a Dock icon, or opens windows nobody asked for.

## Constraints

- **Platform.** macOS 27 and later; deployment target 27.0.
- **Stack.**
  - Swift 6 with strict concurrency checking. SwiftUI for windows. AppKit for the status
    item and the failure overlay where SwiftUI can't do it. Swift Testing.
  - Not sandboxed, because controlling other apps' windows through Accessibility rules it
    out. Hardened Runtime on.
- **Install location.** Tafl runs from `/Applications`.
- **Identity.** Bundle identifier `com.michaelrigart.tafl`.
- **Signing.** Michael's Personal Team, as Linger, Hulder and Muninn now do. The Accessibility
  grant is tied to the certificate, so it should survive rebuilds; ad hoc builds, which CI and
  contributors use, need it again after every rebuild. See
  `docs/superpowers/specs/2026-11-06-tafl-distribution-design.md`.
- **Toolchain.** The same as Linger and Hulder:
  - Xcode through `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` per command.
  - XcodeGen, pinned in the repository's `mise.toml`; the generated project is not tracked.
  - Builds and tests run outside any agent sandbox.
- **Dependencies.** One third-party library: a TOML decoder. `dduan/TOMLDecoder` (MIT, pure
  Swift, `Decodable`, release 0.4.5 on 2026-07-11) is the default choice. The builder may
  pick another, with a reason. No Sparkle, no MASShortcut.
- **Versions.** `YYYYMMDD-HHMM` in local time, with no `v` prefix, for the app version
  string and tags.
- **Repository and license.**
  - Lives at `~/Code/tafl`, under the MIT license, with Rectangle's notice (see "Reuse
    from Rectangle").
  - Becomes a public GitHub repository under `michaelrigart` when Michael says so.
  - Public docs stay free of details about Michael's machine.

## Architecture

Michael asked for a solid codebase, and for the lesson behind Rectangle's planned rework to
shape Tafl from the start. Tafl has three parts.

1. **TaflCore**, a Swift package. It uses Foundation only: no AppKit, SwiftUI,
   ApplicationServices or `#available` checks. It holds:
   - the configuration model and its validation;
   - placements, the pipeline, its steps, and the rules for repeats, display moves,
     display changes and layouts;
   - the window memory and its versioned storage format;
   - the platform interface (described below), declared here and implemented elsewhere.
2. **The platform layer** for macOS 27 (`TaflPlatform27`).
   - It implements the platform interface: Accessibility, the window list, displays and
     their geometry, display-change events, app launch and quit events, and reading
     macOS's tiling settings.
   - Every private symbol, every undocumented attribute and every `#available` check
     lives here.
   - A future macOS gets its own implementation or changes confined to this layer. One
     factory picks the implementation at launch.
3. **The app target.**
   - It holds the composition root, the status item, Settings, the failure overlay,
     hotkey registration, the config file watcher, launch at login, the permission
     onboarding and logging.
   - It holds no business rules.

### The pipeline

Every window move runs through the same five stages. Michael agreed this design on
2026-10-31.

1. **Resolve** (platform): which window, which display, the window's current frame and
   constraints, and the display geometry already corrected for the Dock, menu bar and
   notch. Every read that decides a move happens here; Apply reads only the window it is
   writing.
2. **Calculate** (core, pure): turn the requested placement into a rectangle on the target
   display.
3. **Adjust** (core, pure): an ordered list of small steps, such as gaps, known size
   limits, and keeping the window on screen.
4. **Apply** (core sequence, platform writes): the core drives one write at a time and
   checks the frame read back after each; the platform performs each write and read (see
   "Applying a frame"). This is the only stage that writes to macOS.
5. **Record** (core): update the window memory used by restore, repeats and display
   changes. Record runs whenever Apply may have changed the window, failure or not: it
   keeps the chain's restore frame, and stores the achieved frame as Tafl's own when the
   request ended without an external change and the frame could be read. A failure
   before any write (no window, fullscreen, can't be moved) stops the pipeline before
   Record.

Rules:

- **Features are steps.** A new feature adds a step or a placement, in its own file with
  its own tests. It never edits the pipeline itself.
- **One request type.** Hotkeys, menu actions, layout triggers, new-window events and
  display changes all produce the same kind of request. A request for several windows (a
  layout, a display change) runs the pipeline once per window.
- **Fixed stages, plain types.** Steps are plain Swift types in a fixed order. No plugin
  framework.
- **Settings are passed in.** No stage reads global settings; each receives the
  configuration it needs.

### Placements as data

- A placement is a grid cell: columns, rows, column, row, column span, row span. Halves,
  quarters, thirds and two-thirds are named grid cells. Maximize, maximize height, center,
  restore, larger and smaller are the only special cases.
- One rounding rule: cell edges fall at `round(i × width / n)` from the visible frame's
  edge, so adjacent cells share an edge with no gap or overlap.
- **Recognition.** The same functions answer "which named placement is this frame in, on
  this display?", with a small tolerance. Repeats, display changes and capture use it.

### The platform interface

Names are left to the builder. The contract is:

- **Displays.** Each connected display has:
  - a stable identity (its name as macOS shows it, plus vendor, model and serial numbers);
  - its frame and its corrected visible frame, in one coordinate space;
  - its position relative to the others.

  Reconfiguration begin and end events.
- **Windows.**
  - The focused window, and the windows of running apps on the current Space.
  - For each window: its app's bundle identifier and process, its title, its frame,
    whether position and size are settable, its minimum size if the app exposes one, and
    its window id when it can be resolved.
  - Events: window created, moved, resized, title changed and destroyed; app launched and
    quit.
  - Which apps can't be observed, and for which events (registering for an event can
    fail; see "Failures").
- **Writing a window.** Three primitives, each one Accessibility call with a timeout: read
  the frame, set the size, set the position. Each returns its result or a typed failure:
  the app didn't respond, the window can't be moved, or the window is fullscreen. A write
  session wraps a sequence of them for one app: it switches Enhanced UI off at the start
  and restores it at the end. The core judges the results, including a refused size and
  an external change (see "Applying a frame").
- **Raising windows.** Bring given windows to the front in order, and make the last one's
  app frontmost. A failure is logged and never fails the layout. The core passes an
  admission check that the platform asks, on the queue where that call runs, before each
  raise, each frontmost write and the activation fallback (the app's Accessibility queue
  for the raise and the frontmost write, the main actor for the fallback); once it answers
  no, nothing more is raised.
- **The pointer's display.**
- **macOS's tiling settings** (read only).
- **The Accessibility permission state.**

A fake implementation of the interface drives the core's tests.

### Coordinates

AppKit rectangles and Accessibility rectangles are separate types. They are converted only
at the platform boundary. The core works in one space.

### The quality bar

- Version checks, private symbols and undocumented attributes live only in the platform
  layer.
- No central object that every component reaches into. Each component has one
  responsibility and receives its dependencies explicitly. No dispatch through
  `NotificationCenter`.
- Coordination is event-driven. A timeout is an upper bound on a wait, never a way to let
  things settle, with two named exceptions where macOS gives no signal at all:
  - the 25 ms cross-display reapply in "Applying a frame";
  - the quiet period that marks a display change as settled (see "Display changes").

  The feasibility check measures both, and confirms or removes them. No other fixed delay
  is allowed.
- Every Accessibility call runs off the main actor and off Swift's cooperative thread pool,
  with a timeout on the target app.
- Every private symbol is looked up at run time. If one is missing, the feature that needs
  it uses its fallback, and Settings says so. Tafl never crashes over it.
- `@unchecked Sendable` and `nonisolated(unsafe)` are allowed only with a stated reason.
- Every placement, step and rule has a test with exact expected rectangles.
- Logging is lazy: nothing is read from an app only to build a log message.

## How it works

### Actions

The default shortcuts are Rectangle's alternate set, which Michael uses today. Each action
has a name used in the config file.

| Action | Default |
|---|---|
| `left-half`, `right-half`, `top-half`, `bottom-half` | ⌃⌥←, ⌃⌥→, ⌃⌥↑, ⌃⌥↓ |
| `top-left`, `top-right`, `bottom-left`, `bottom-right` | ⌃⌥U, ⌃⌥I, ⌃⌥J, ⌃⌥K |
| `first-third`, `center-third`, `last-third` | ⌃⌥D, ⌃⌥F, ⌃⌥G |
| `first-two-thirds`, `center-two-thirds`, `last-two-thirds` | ⌃⌥E, ⌃⌥R, ⌃⌥T |
| `maximize`, `maximize-height` | ⌃⌥↩, ⌃⌥⇧↑ |
| `center` (keeps the size) | ⌃⌥C |
| `restore` (the frame before Tafl's first action on it) | ⌃⌥⌫ |
| `larger`, `smaller` (by `step` points on every side) | ⌃⌥=, ⌃⌥- |
| `display-left`, `display-right`, `display-up`, `display-down` | ⌃⌥⌘←, ⌃⌥⌘→, ⌃⌥⌘↑, ⌃⌥⌘↓ |
| `display-under-pointer` | ⌃⌥⌘M |

- **Thirds follow the display's orientation.** On a portrait display, thirds are rows.
- **Display moves:**
  - A directional move picks the nearest display whose centre lies in that direction.
  - With no display in that direction, it falls back to Rectangle's order: displays
    sorted top to bottom, then left to right, wrapping around. ← and ↑ take the previous
    display, → and ↓ the next.
  - With one or two displays, this gives the same result as Rectangle's previous and next
    display on the same keys, in any arrangement. With three or more, the direction wins.
  - The window keeps its recognised placement. Otherwise it keeps its relative position
    and size.
  - With a single display, nothing moves and the overlay says so.
- **Larger and smaller** stop at the visible frame and at the window's minimum size.
- **Restore** returns the window to the frame it had before a chain of Tafl placements
  began, as it was, even partly off-screen (display-change rule 2 places a remembered frame
  the same way; larger, smaller and the named placements keep the window on screen).
  - A chain starts when Tafl places a window that the user placed last (or never placed).
    So once the user moves or resizes the window, the next placement records a new restore
    frame, as in Rectangle.
  - Shortcut, menu and layout placements count. Display-change rules don't, because their
    old frame was on a display that may be gone.
  - Where the frame goes follows the display it was recorded on. While that display is
    unchanged, the frame is exact: a Dock or menu bar change (shown, hidden, resized, moved)
    counts as unchanged. When the display only moved, the frame is translated by the move,
    with its size kept. When its resolution changed, the frame is mapped onto the display as
    it is now. When the display is no longer connected, the frame is mapped onto the
    window's current display. A target with less than a quarter of it on any display is kept
    on screen; this is the only pull onto the screen, for restore and for rule 2.

### Repeats

A repeat is the same action on the same window, while the window is still where that
action put it. `repeat` in the config file sets what a repeat does:

- **`displays`** (default, Michael's Rectangle setting): repeating `left-half` moves the
  window to the right half of the display picked by `display-left`, and `right-half`
  mirrors it with `display-right`. That includes the fallback order, so with two displays
  a repeat always reaches the other one, as in Rectangle. With one display, nothing
  changes. Other actions don't repeat.
- **`sizes`:** repeating a half cycles ½ → ⅔ → ⅓ of the display along that axis.
- **`none`:** a repeat does nothing.

### Display changes

- **A display setup** is the set of connected displays, by identity. Resolution, scaling,
  rotation, arrangement, mirroring and which display is main are not part of it.
- **Last-known frames.** macOS gives no reliable notice before a display disconnects. So
  Tafl keeps every window's last-known frame per display setup, from window-moved and
  window-resized events. It stops recording for a setup as soon as a reconfiguration
  begins. A frame is stored with its display's frame and visible frame, and relative to the
  visible frame. It is placed back by the Restore rule above (exact, translated or mapped),
  so a change of resolution maps it and a Dock change leaves it where it was.
- **Settling.** macOS signals neither the end of a docking sequence, which often fires
  several reconfigurations, nor the end of its own window relocation. Tafl treats a
  display change as settled after a quiet period with no reconfiguration and no
  window-moved events. The length comes from feasibility check 3, with an upper bound of
  3 s.
- **What triggers the rules.** Only a settled setup that differs from the setup before the
  change. So:
  - a display that drops out briefly and returns, on wake or when a monitor sleeps, moves
    nothing;
  - a change of resolution, arrangement or main display moves nothing;
  - a setup that holds a placeholder display (no name, vendor "unkn" and model "virt", which
    macOS shows briefly during a DarkWake) is never a setup: the rules do not run for it, nothing
    moves, the active layout and the last-known setup stay, and the next real setup is handled
    as usual, compared with the setup before the placeholder. Such a setup is never recorded,
    remembered or saved, so when Tafl starts on one with no setup remembered (a first launch, or a
    memory that failed to load), the next real setup is a first setup: recorded and remembered,
    with no rule run. Meanwhile no shortcut or layout targets a placeholder: placement and
    navigation see only the other displays.

When the display setup changes, each visible window (on any display's current Space) is
handled by the first rule that applies:

1. **A layout claims the new setup:** the window is placed by that layout, if the layout
   matches it.
2. **The setup was seen before:** a window that existed then goes back to its last frame
   on it.
3. **The window was in a recognised placement** on the display it left: it gets the same
   placement on the display macOS moved it to.
4. **Any other window** keeps its relative position and size on the display macOS moved it
   to, pulled fully on screen.

Adding a display that no layout claims and that hasn't been seen before moves nothing.

- **A layout beats memory.** Docking again applies the layout that claims the desk setup,
  even if windows were moved by hand during the previous docked session. A layout is what
  the user wants for that setup; memory only covers setups without one.
- **Windows on hidden Spaces,** full-screen windows and windows of apps Tafl can't observe
  (see "Failures") are not handled. Tafl can't reliably see them, or has no last-known
  frame for them, so they stay where macOS put them.
- **Window memory** lives in `~/.local/state/tafl/`, versioned, so it survives a Tafl
  restart. It is runtime state, not configuration. It also records which layout is active.
- **Window matching:** an entry matches by window id, checked against the owning process,
  because titles change. Entries for closed windows are dropped.
- **macOS's own behaviour comes first.** macOS 27.2 restores windows itself when a known setup
  returns (see "Measured on macOS 27.2"), so rule 2 steps aside for a window macOS restored to
  its last frame.

### Layouts

A layout names an optional display setup, an optional shortcut, and where windows go.

```toml
[[layouts]]
name = "Desk"
displays = ["Studio Display"]   # applies automatically when exactly these are connected
shortcut = "ctrl+opt+cmd+1"     # optional

  [[layouts.windows]]
  app = "com.apple.Terminal"
  place = "first-third"

  [[layouts.windows]]
  app = "com.apple.Safari"
  title = "*Docs*"              # optional glob on the window title
  place = "last-two-thirds"
  display = "Studio Display"    # required when the layout names more than one display
```

- **Triggers.**
  - A layout applies automatically when the connected displays are exactly its
    `displays`, in any order.
  - Its shortcut applies it at any time, on the current setup.
  - A layout with neither is a config error. Two layouts that claim the same setup are a
    config error.
- **Matching.** Entries are checked top to bottom, and the first match wins for each
  window. An entry matches every window of that app on the current Space, narrowed by
  `title`. Several matching windows all get the same placement, stacked. Windows that
  match no entry are left alone.
- **Which display an entry uses:** its `display`, else the layout's only display, else
  the window's current display. If that display isn't connected, the window's current
  display. So a desk layout applied by shortcut while undocked arranges the windows on the
  built-in display.
- **Apps that aren't running** are skipped. Tafl never launches anything.
- **Raising.** A layout applied by its shortcut or from the menu brings the windows it
  matched to the front, so the first entry's windows end on top and that app has keyboard
  focus. The windows of one entry keep their order among themselves. A window that was
  already in place is raised too; one that failed or vanished is not. A layout that applies
  on a display change leaves the window order and focus alone, and so does a run that a
  display change stopped. A run that a newer layout overtook raises nothing, so the newer
  layout's windows stay on top. Raising stops as soon as the run is no longer current: a
  newer layout, a display change, or Tafl beginning to quit, that arrives partway through
  leaves the remaining windows unraised, and each step is checked just before it is made, on the queue where
  that step runs.
- **While a layout is active,** a window created later is placed by it, if an entry
  matches. A layout stops being active at the next display change, or when another layout
  is applied.
- **A config reload never moves a window.**
  - The active layout is looked up again by name. If it is gone (removed or renamed), no
    layout is active. If its entries changed, the new entries apply to windows created
    from then on, and to pending title checks.
  - A layout that now claims the current setup waits for the next display change, or is
    applied by its shortcut or from the menu.
  - At launch, the remembered active layout is looked up by name in the same way.
- **Titles of new windows.** Many apps set a window's title just after creating it. An
  entry with `title` is checked when the window is created, and once more at its first
  title change if that comes within 1 s and the user hasn't touched the window. Later
  title changes never move a window. For an app whose title changes can't be observed,
  the check at creation is the only one.
- **The user always wins.** A window the user moves after a layout placed it is never put
  back.
- **Display names** are the names macOS shows. Settings lists the connected displays with
  the exact names to use. When two connected displays share a name, Settings shows an
  identifier to use instead.

### The config file

- **Location:** `~/.config/tafl/config.toml`. The file is the single source of truth
  (Michael's decision). It may be a symlink.
- **Contents:** every setting there is.
  - Shortcuts for every action, with `"none"` to unbind one.
  - `repeat`, `gap` (points between windows and to the display edges, default 0) and
    `step` (for larger and smaller, default 30).
  - Layouts.
  - `menu-bar-icon` (default on) and `launch-at-login` (default on).
- **Defaults.** Without a file, Tafl runs on its built-in defaults. Settings offers to
  create a starter file: every setting at its default, commented. That is the only time
  Tafl writes the file, and it never overwrites one.
- **Live reload.** Tafl watches the file's directory, because tools such as chezmoi replace
  the file rather than edit it. When the file is a symlink, Tafl also watches the
  directory of the file it finally points to, and resolves the link again after every
  change, so a replaced link or a replaced target is followed. A change applies within a
  second, without a restart.
- **Errors.** A file that doesn't parse or doesn't validate is rejected as a whole. Tafl
  keeps the last good configuration, and Settings and the menu show the error with its
  line. Unknown keys are errors, so typos never pass silently.
- **Shortcuts that can't be registered** (for example because another app holds the key)
  don't reject the file. At launch and on every reload, Tafl unregisters its whole old set,
  then registers the new one. Each shortcut that fails is left unbound, shown with its
  action in Settings and the menu, and logged. Tafl tries it again at the next reload, wake
  or input source change. The rest of the configuration applies.
- **Shortcut syntax:** modifier names and a key, such as `"ctrl+opt+left"`. Two actions on
  the same shortcut are an error.
- **Keys are characters.** A key in the file is the character the current keyboard layout
  prints on it, so the file and Settings match the keycaps. This matters because Michael
  types on ABC-AZERTY.
  - Tafl translates characters to key positions with the current layout, and registers
    again when the input source changes.
  - A character the layout produces only with a modifier not listed in the shortcut
    (such as a digit that needs Shift) is a config error that names the key to use
    instead.
  - **Built-in defaults are key positions:** the same physical keys as Rectangle's
    alternate set. Settings and the starter file show them as the characters the current
    layout prints. So the default shortcuts stay on the keys Michael's fingers know, even
    where AZERTY prints a different character (`smaller`, and the new `M`).

### Settings

Settings shows the configuration in plain language and never edits it.

- **Overview:** the config file's path and status (loaded, using defaults, or rejected with
  the error and its line), any shortcuts that couldn't be registered, with Open in Editor,
  Reveal in Finder, and Create Starter File (only when no file exists).
- **Shortcuts:** every action, its shortcut and a one-line description, grouped. It doubles
  as a cheat sheet.
- **Layouts:** each layout, its trigger, its entries, and whether it is active now.
- **Displays:** the connected displays with the names to use in the file, and which layout
  claims the current setup.
- **Capture Current Arrangement:** builds a layout snippet for the current setup from the
  windows on the current Space, in their recognised placements. Windows in no recognised
  placement are listed as comments. It shows the snippet and copies it to the clipboard.
- **macOS tiling:** whether macOS's own drag tiling is on, with a button that opens the
  right page of System Settings.
- **Permissions:** the Accessibility state, with a button to grant it.
- **About:** the version, and Copy Diagnostics: macOS version, display count, config
  status, capability states and recent failure categories. No app names, window titles or
  paths.

### Dragging

- Dragging is left to macOS's tiling: edges for halves, corners for quarters, the menu bar
  to fill, and Option-drag. On Michael's Mac it is currently switched off, probably by
  Rectangle, so he switches it back on.
- Tafl never changes macOS's tiling settings. Settings shows their state.
- A window macOS tiled counts as placed through recognition, so it follows the display
  rules like any other.
- `gap` defaults to 0. If macOS's tiled-window margins are on, Settings says that `gap`
  should match them for a consistent look.

### Applying a frame

- **One path** for every placement, based on Rectangle's technique. The core drives it
  through the platform's primitives, one write at a time:
  1. Choose the order: size first when crossing displays or when the window is off screen.
     Otherwise use the order that keeps the window inside the target display.
  2. Write one part (size or position), read the frame back and check it (below), then
     write the next part using what was accepted.
  3. Retry the size once if it is off by more than 1 point.
  4. After a cross-display move, reapply once more after 25 ms.
- **One request at a time per window.** Requests for the same window run in order. A newer
  request waits for the Accessibility call in flight, then cancels what is left of the
  older request, including its pending reapply.
- **Checking each read-back.** While it writes, Tafl keeps an expected frame for the
  window, starting from the frame Resolve read.
  - The part just written may differ from the request: macOS accepted, clamped or refused
    it. The expected frame takes the value read.
  - The other part must be unchanged, except for macOS's own adjustments that feasibility
    check 2 measures, such as a size clamped to the new display after a cross-display
    position write. Each adjustment is named, computed exactly by the core, and tested.
  - Any other difference is an external change: the user's or macOS's.
- **Window events during a write.** Accessibility events carry no frame, so Tafl reads
  the frame when it handles one. A frame read during a write is checked the same way, and
  the part being written may also differ. The check happens before the next write, not at
  the end of the sequence.
- **An external change stops the request at once:** no further write, no retry, no
  reapply. The window counts as moved by the user from then on, and the overlay says it
  was moved during placement.
- **The limit.** Accessibility has no atomic or conditional write, so two changes can't
  be seen:
  - a change made after a read-back that touches only the part the next write sets: the
    write replaces it;
  - a change to the part being written, made between the write and its read-back: it is
    taken as macOS's.

  A drag that goes on after either gap is seen at its next event. Each gap lasts one
  Accessibility call; feasibility check 2 measures how long that is.
- **After a request,** the expected frame is the frame achieved, and any later frame that
  differs is external. Restore chains, "the user always wins" and last-known frames all
  use this rule.
- **The reapply** reads the frame first. It goes ahead only if the window is still at the
  frame achieved, no newer request for it exists, and no display reconfiguration has
  begun. Otherwise it is dropped.
- **Where it lives.** The ordering, cancellation, checks and the reapply's timing live in
  the core, and are tested on the injected clock against the fake platform. The platform
  performs each write and read.
- **A display reconfiguration that begins** while Tafl is applying a layout or the
  display-change rules stops that run. The rules run again once the new setup settles.
- **Enhanced UI:** switched off for the target app for the whole write session, and
  restored after, following Rectangle's policy for Chromium browsers and assistive
  technology.
- **Timeouts:** each Accessibility call has a timeout on the target app. An app that
  doesn't answer fails the action with "\<App> didn't respond".
- **Apps that refuse a size** are aligned to the target's shared edges and kept on screen.
  The overlay says the app kept its own size. A size short by less than one of the app's
  resize increments, as in terminal apps, counts as success.
- **Fullscreen windows and sheets** are refused, and the overlay says why.

### Failures

- Every failed action shows a short overlay on the window's display, for about 1.5 s, with
  fixed wording: no window, not responding, size refused, can't be moved, fullscreen,
  moved during placement, no display that way, or permission missing. It is also logged.
- A failure is never retried on its own. The next user action tries again.
- **Permission lost** (for example after a macOS update): Tafl notices within about 2 s, or on
  the next action, shows the onboarding again, and logs it. A grant that comes later
  relaunches Tafl.
- **Apps Tafl can't observe.** macOS can refuse to deliver an app's window events.
  Shortcuts still work on that app's windows, and so does a layout applied by shortcut or
  from the menu. Without its events, though, Tafl has no last-known frames and doesn't see
  new windows, so the display-change rules and an active layout leave the app's windows
  alone. Each such app is logged, and the count is in Copy Diagnostics.
- **After wake or a user switch,** Tafl re-registers its hotkeys and re-creates its
  observers. An app that observed fine before, and fails to register during the wake
  transient, is tried again 3 s and 10 s after the restart: one that registers then is
  observed again, and takes part in the display-change rules and the active layout; one that
  still fails after the last try stays unobservable. An app that was already unobservable
  before the restart is not tried again. That baseline is what was unobservable when the first
  pending restart began, less the apps whose tries are still pending, so a newer restart takes
  over an earlier one's pending tries, while an app the tries gave up on is not tried by the
  next restart. An app's quit or Tafl stopping ends its tries.

### Menu bar icon

- The menu has the layouts (apply one, with the active one checked), Capture Current
  Arrangement, Settings, the config status when the file was rejected or a shortcut couldn't
  be registered, and Quit.
- With `menu-bar-icon = false`, opening Tafl again from Finder or Spotlight opens Settings.

### Permissions and first launch

- Accessibility is required. Without it, Tafl registers no hotkeys and shows a short
  onboarding window that explains the permission and opens the right page of System
  Settings.
- **Noticing the switch.** Tafl notices a switch of the Accessibility permission within about
  2 seconds. A running process's own answer is cached (measured on macOS 27.2.1: the
  `TCCAccessPreflight` answer never changes, and `AXIsProcessTrusted()` twice cached the old
  value for good while System Settings was still writing the change), so on each system
  notification, and again 0.5 s and 2 s later, Tafl asks a short-lived copy of its own
  executable (`-TaflCheckAccessibility`), which a fresh process answers right and which exits
  0 for granted and 1 for not, before any AppKit code runs. A copy that fails, or does not
  answer within 1 s, changes nothing. A grant that arrives in a process that ran without it
  relaunches Tafl, because observing started in that process right after the grant can fail
  for every app. Reopen Tafl in the onboarding window is the manual fallback.
- **Launching for testing.** Start the app with `open` or Finder. Launched from a terminal,
  macOS attributes the Accessibility permission to the terminal (learned on Linger).

### Startup and quit

- Launch at login goes through `SMAppService`.
- At launch, Tafl loads the config, reads the window memory, and registers hotkeys. It
  doesn't apply a layout at launch unless the setup changed since the last time it ran.
- At quit, it removes its observers and hotkeys. It leaves every window where it is.

### Logging

Tafl uses Unified Logging with subsystem `com.michaelrigart.tafl`. Actions, failures,
display changes and config reloads are logged at notice level so they persist. Read them
with `/usr/bin/log`, because zsh has a `log` builtin.

## Verification

- **Core unit tests** (Swift Testing) pin exact rectangles:
  - every named placement on landscape, portrait and ultrawide visible frames, including
    frames whose size doesn't divide evenly, with no gaps or overlaps between neighbours;
  - gaps, larger and smaller, center and restore;
  - recognition of every placement, with and without gaps, and its tolerance;
  - repeats in each mode, including "the window moved since";
  - directional display moves and the fallback order in side-by-side, stacked, diagonal
    and three-display arrangements, matching Rectangle's result for one and two displays;
  - restore chains: a user move starts a new chain, display-change rules don't set a
    restore frame, and a restore frame from a missing display is mapped;
  - each display-change rule and their order; a return to the same setup, and a change of
    resolution or arrangement, move nothing; a layout beats memory;
  - settling: several reconfigurations in a row produce one run of the rules, on the
    injected clock;
  - layout triggers, matching order, which display an entry uses, title globs including
    the first title change and an app whose title changes can't be observed, stacking, and
    "the user always wins";
  - config reloads that remove, rename or change the active layout, or add a layout for
    the current setup: none of them moves a window;
  - applying a frame on the injected clock against the fake platform:
    - the order of writes, the size retry and the cross-display reapply;
    - Tafl sets the size, the user drags the window before the read-back: the change is
      seen, and the position write never happens;
    - a frame read on an event during a write that differs in the part not being written
      stops the request before the next write;
    - each named macOS adjustment passes, and any other change to the unwritten part
      stops the request;
    - a change made after a read-back that touches only the part being written next is
      replaced, as the stated limit says;
    - the reapply reads the frame first, and is dropped after a newer request, an
      external change or a reconfiguration;
    - a newer request for the same window waits for the call in flight, then cancels the
      rest of the older one;
  - a placement whose size was refused still records its restore frame and achieved frame,
    and is reported; one stopped by an external change records no achieved frame;
  - shortcut activation against a fake registrar: one shortcut fails partway through a
    reload, the rest of the configuration applies, the failure is reported, and nothing
    from the old set stays registered;
  - shortcut translation from characters to key positions with a US and an AZERTY layout
    table, the modifier error, and defaults shown as the current layout's characters;
  - config parsing and validation: every error case, with its line; unknown keys; duplicate
    shortcuts; overlapping layouts; the last good configuration kept on error;
  - window memory round-trips, and a file from an unknown future version is refused and
    never overwritten;
  - the pipeline against the fake platform: steps run in order; a failure before any write
    stops the pipeline before Record and is reported; nothing is retried on its own.
- **How tests wait:** tests wait only through the shared test support (`TaflTestSupport`), and
  engine tests on the engine being quiescent; a test that cannot reach its condition fails at
  its bound instead of hanging; `scripts/lint-tests` enforces it in CI.
- **A platform probe** for Debug builds only, started with a launch argument as in Linger.
  It runs from `/Applications` and logs the window list, display identities, the
  corrected visible frames, and the event order during a display change. It is run again
  on every new macOS release.
- **Manual acceptance on Michael's Mac:**
  - every default shortcut, on the ultrawide and on the built-in display;
  - repeats across two displays;
  - display moves in each direction and to the display under the pointer;
  - undock, dock and connect a second display, with and without a layout for each setup;
  - a layout applied by shortcut, and a new window placed while it is active;
  - `chezmoi apply` with a changed file, and with a broken file; a symlinked config file
    whose target is edited in place, and replaced;
  - a Chromium or Electron app, a terminal app, and an app with a minimum size;
  - sleep and wake, a restart, and a reboot;
  - Accessibility revoked and granted again;
  - idle CPU stays at 0%.

## Delivery

- **v1 deliverable:** Tafl.app, built locally, installed in `/Applications`, launching at
  login and replacing Rectangle.
- **The plan's first task is a feasibility check on macOS 27.2,** run from `/Applications`,
  before any interface work:
  1. **Windows.** Whether the Accessibility window list covers only the current Space.
     Whether app-level created, moved, resized and title-changed notifications arrive
     reliably for a native app, a Chromium or Electron app, a terminal and Finder, and how
     quickly.
  2. **Applying a frame.** Rectangle's order, read-back and retry across the built-in
     display and the ultrawide, whose heights differ. Whether `AXEnhancedUserInterface`
     still matters on 27.2, and whether the 25 ms reapply is still needed. Which changes
     macOS makes on its own to the part Tafl didn't write, such as a size clamped after a
     cross-display position write, and exactly how, so each can be named. How long one
     write and one read-back take.
  3. **Display changes.** The order of events when undocking, docking and connecting a
     second display: the reconfiguration callbacks against the moved events from macOS's
     own relocation. The quiet period after which no further reconfigurations or macOS
     window moves arrive. What wake from sleep and a sleeping monitor fire. Whether macOS
     27.2 restores window positions itself when a known setup returns.
  4. **Display identity.** The names and identifiers macOS reports for the built-in display
     and the external ones, and whether they stay the same across reconnects and reboots.
  5. **Geometry.** `_AXUIElementGetWindow` is available. Whether the auto-hidden Dock still
     reserves space (Rectangle #1922). Whether `visibleFrame` goes stale after a Dock
     change.
  6. **macOS tiling.** With macOS's drag tiling on, whether a tiled window's frame is
     exactly a half or quarter of the visible frame, with margins on and off.
  7. **Hotkeys.** Every default shortcut registers through Carbon on 27.2, and none
     conflicts with a system shortcut. Whether registering a key another app already holds
     fails or silently succeeds. Characters translate to the right key positions on
     ABC-AZERTY and on a US layout, and a change of input source is noticed.
- **Michael at the Mac.** Checks 2 to 4 need him to dock, undock and connect displays, for
  about half an hour.
- **Stop and bring it to Michael** if:
  - check 1 shows that windows can't be read or moved reliably;
  - check 2 shows that macOS changes the part Tafl didn't write in ways the core can't
    compute exactly, so they can't be told from an external change;
  - check 3 shows that last-known frames can't be kept from before macOS moves the
    windows, so rules 2 to 4 in "Display changes" can't work as written;
  - check 3 shows that macOS's own restore conflicts with Tafl's rules;
  - check 3 shows that macOS keeps moving windows for longer than 3 s after a change, so
    Tafl's placements would be overwritten.

  Each of these changes what gets built.

## Reuse from Rectangle

Rectangle is MIT. Tafl may port its code, keeping its notice: "Copyright (c) 2019-2026 Ryan
Hanson. Based on the Spectacle app, Copyright (c) 2017 Eric Czarny." The MIT text and both
lines go into Tafl's license file.

- **Port and adapt** to Tafl's types, each with Swift Testing tests (Rectangle's tests
  ported where they exist). Paths are relative to `Rectangle/` in Rectangle 2.0.4:
  - `HalfSplitFrameCalculation` (`WindowCalculation/WindowCalculation.swift`) and the
    boundary rounding in `WindowCalculation/VerticalEighthCalculation.swift`;
  - the cycle order (`CycleSize.swift`) and the repeat rule ("same action, window not
    moved");
  - `GapCalculation`, `DisplayTransfer` and `relativePositionedRect`
    (`NextPrevDisplayCalculation.swift`);
  - the Dock and menu bar corrections in `ScreenDetection.swift`;
  - `ClampedWindowAligner`, `EdgeAlignment`, `WindowFrameBounds` and
    `ImmediateFrameOrder`;
  - the Enhanced UI policy and `setImmediateFrame` (`AccessibilityElement.swift`);
  - the window-id and front-window fallbacks, including the Emacs case;
  - the coordinate flip in `CGExtension.swift`, as typed conversions.
- **Not taken:** the 84 per-cell classes, the `Defaults` registry, `WindowManager`,
  NotificationCenter dispatch, MASShortcut and Sparkle.
- **Rectangle Pro** is closed source. Only its public feature list was used.
- **Loop** (`MrKai77/Loop`) is GPL-3.0. Implementers never read or copy its source.

## Left to the builder

- Code structure inside the three parts, and all names.
- The hotkey mechanism: a small Carbon wrapper, or a library that registers shortcuts given
  in code. Shortcuts are never stored outside the config file.
- The TOML library, within the constraints above. If it can't report line numbers, the
  builder finds another way to show where an error is.
- The storage format of the window memory, as long as it is versioned.
- Accessibility timeout values, and the tolerance used by recognition.
- The visual design of Settings, the overlay and the icon.

## Decisions

**Michael decided (2026-10-31 and 2026-11-01):**

- Build his own app, and take the lesson of Rectangle's planned `WindowManager` rework into
  account from the start.
- The pipeline architecture as described: five fixed stages, features as steps, every
  input feeding one request type, a core package without AppKit, and the platform layer as
  the only place that touches macOS.
- No Spaces, because there is no public API.
- Multiple displays, sometimes two at once. Display changes should behave logically; the
  rules are my proposal.
- The config file is the single source of truth, shown in a simple interface.
- Layouts are defined in the config file and restore automatically.
- Everything can be done with keyboard shortcuts.
- A solid codebase and a polished app from the first release.

**My calls** (confirmed by Michael at sign-off, 2026-11-01):

- The name Tafl, bundle identifier `com.michaelrigart.tafl`, and `~/Code/tafl`.
- macOS 27 and later only; not sandboxed, and therefore never on the App Store.
- Dragging left to macOS's tiling, which Michael switches back on. No drag-to-snap of
  Tafl's own in v1.
- Default shortcuts from Rectangle's alternate set, plus the display moves on ⌃⌥⌘ and the
  arrow keys, and ⌃⌥⌘M for the display under the pointer.
- `repeat = "displays"` by default, matching Michael's Rectangle setting.
- TOML at `~/.config/tafl/config.toml`, with `dduan/TOMLDecoder`. Window memory in
  `~/.local/state/tafl/`.
- A rejected config file keeps the last good configuration. Unknown keys are errors.
- A change by the user or macOS during a placement stops it at once, with an overlay;
  Tafl never writes over a change it has seen.
- A config reload never moves a window; the active layout is looked up again by name.
- A shortcut that can't be registered leaves only that action unbound, and is reported;
  the rest of the file applies.
- The display-change rules and their order. A setup is the set of connected displays;
  only a settled change of that set runs the rules, so wake and resolution changes move
  nothing. A layout beats memory on re-docking.
- A quiet period, measured in the feasibility check and capped at 3 s, marks a display
  change as settled. This is one of two named exceptions to "no settling delays".
- Directional display moves with Rectangle's order as the fallback, so one- and
  two-display results match Rectangle on the same keys.
- Shortcut keys in the file are characters on the current layout. Defaults keep
  Rectangle's physical keys.
- Restore follows Rectangle's chain rule. Layout placements set a restore frame;
  display-change rules don't.
- Windows on hidden Spaces and full-screen windows are left to macOS on display changes.
- The layout rules: exact display-set triggers, first match wins, which display an entry
  uses, stacking, title checks at creation and first title change within 1 s, no
  launching, and the user always wins.
- Capture Current Arrangement copies a snippet, rather than writing the file.
- A short overlay for every failure; no beeps.
- A menu bar icon that can be switched off; launch at login on by default.
- Ad-hoc signing, XcodeGen in `mise.toml`, and `YYYYMMDD-HHMM` versions.
- English only.
