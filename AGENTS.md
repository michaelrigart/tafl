# Tafl

Design and behaviour: `docs/superpowers/specs/2026-11-01-tafl-design.md`.
Design-record rules (specs, plans, status, commits) are in the global agent instructions.

## Commands

Run all of these outside any agent sandbox: SwiftPM's nested `sandbox-exec`, the module
cache under `/var/folders` and the Xcode build service fail inside it. Prefix each with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` unless `xcode-select -p` already
points at Xcode, and don't change `xcode-select`.

- Core tests: `swift test --package-path Packages/TaflCore`
- Platform tests: `swift test --package-path Packages/TaflPlatform27`
- Generate the project: `mise exec -- xcodegen generate` (`Tafl.xcodeproj` is not tracked)
- Build: `xcodebuild -project Tafl.xcodeproj -scheme Tafl -configuration Debug -derivedDataPath build/dd.noindex -quiet build`
- Release build: the same with `-configuration Release`; `scripts/verify-app` accepts only
  Release builds.
- Without the signing certificate (ad hoc): add `CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=` to
  either build.
- Install (quit Tafl first: the running copy's grant check runs the binary on disk): `rm -rf /Applications/Tafl.app && ditto build/dd.noindex/Build/Products/Debug/Tafl.app /Applications/Tafl.app`
  (`ditto` merges into an existing bundle and would keep stale files)
- Run: `open /Applications/Tafl.app`
- Script tests: `/usr/bin/python3 -m unittest discover -s scripts/tests -p 'test_*.py'` (the
  changelog tool), `scripts/tests/test-release-dry-run` and
  `scripts/tests/test-verify-app <Release Tafl.app> <Debug Tafl.app>`
- Verify a built app: `scripts/verify-app [--team <ID>] <Tafl.app> [<version>]`. It fails on a
  bad signature, non-empty entitlements, `LSUIElement` not true, a wrong bundle identifier or
  version, the probe in the executable, or (with `--team`) a different `TeamIdentifier`.
- Release: `scripts/release [--dry-run] [--version <YYYYMMDD-HHMM>]`, on Michael's Mac only (it
  needs the signing certificate and pushes). Use `--dry-run` to check it; never run it for real
  unless Michael asks. `--version` resumes a failed release.
- Regenerate the app icon and menu bar icon PNGs from `design/`: `design/render` (needs
  `rsvg-convert`)

## Releases and CI

- A user-visible change adds an entry to `CHANGELOG.md` under `## [Unreleased]`, under `Added`,
  `Changed`, `Fixed` or `Removed`. `scripts/release` moves it into the release.
- CI (`.github/workflows/ci.yml`) runs on `xcode-27` and signs ad hoc, because the certificate
  stays on Michael's Mac. It builds with `CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=`, as anyone
  without the certificate does.
- Distribution design: `docs/superpowers/specs/2026-11-06-tafl-distribution-design.md`.

## Where code goes

- `TaflCore` imports only Foundation, the standard library's Synchronization, and
  TOMLDecoder (exact 0.4.5). No AppKit, SwiftUI, ApplicationServices, Carbon,
  CoreGraphics-only API, `os` or `#available`.
- Private symbols, undocumented attributes and `#available` live only in `TaflPlatform27`.
  Resolve each private symbol at run time with `dlsym`; a missing one becomes a fallback and
  a capability state, never a crash.

## Rules an agent gets wrong

- Run Tafl from `/Applications`, started with `open`. Launched from a terminal, macOS gives
  the Accessibility grant to the terminal.
- Builds are signed with Michael's Personal Team, so the grant should survive rebuilds. That is
  confirmed for Hulder (2026-11-03); for Tafl it is confirmed once acceptance 2 of the
  distribution design is recorded. Switching from an ad hoc build to a team-signed one needs the
  grant once, after `tccutil reset Accessibility com.michaelrigart.tafl` (which Michael runs).
  Ad hoc builds (`CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=`, which CI and contributors use) need
  the grant again after every rebuild. To grant it: quit Tafl, start it with `open` and switch
  it on in System Settings, Privacy & Security, Device Control and Data Access (the Accessibility
  permission). The onboarding window's button opens that page. Tafl notices a switch within about
  2 seconds by asking a short-lived copy of itself (`-TaflCheckAccessibility`, which exits 0 or 1),
  because a running process's own answer is cached. It relaunches itself on a grant it did not
  start with (observing started in that process right after the grant can fail for every app).
  Reopen Tafl in the onboarding window is the manual fallback. Whether a renewed certificate
  (yearly) keeps the grant is unconfirmed.
- Paths: the config is `~/.config/tafl/config.toml` (it may be a symlink; Tafl writes it only
  as a starter file when none exists, on request); the window memory is `~/.local/state/tafl/memory.json`.
- While Tafl runs, a zero-length `config.toml` is read as a save in progress and ignored (an
  editor may truncate the file before it writes). To return to the built-in defaults, delete
  the file; an empty file at launch does mean defaults.
- A memory change an older reader can't decode (for example a new `Action` or
  `NamedPlacement` case) must bump `WindowMemory.fileVersion`.
- A bare `log` is a zsh builtin. Use `/usr/bin/log`; the subsystem is
  `com.michaelrigart.tafl`.
- Never write `com.apple.WindowManager` or the user's config file
  (`~/.config/tafl/config.toml`).
- Every `xcodebuild` run that compiles (`build`, `test`, `archive` and the like) passes a
  `-derivedDataPath` that ends in `.noindex`: Spotlight skips those folders, so builds never show
  up in Spotlight or Alfred. The default is `build/dd.noindex`; a parallel or scratch build uses
  `build/dd-<name>.noindex`.
- Never open Loop's source. Rectangle ports keep its notice in `LICENSE`.

## Probe

A Debug-only probe in `Tafl/Probe/` exercises the platform types Tafl ships, so a new macOS can
be checked by rerunning it. It needs the Accessibility grant and quits when it finishes.

- Launch: quit Tafl first, then `open /Applications/Tafl.app --args -TaflProbe <subcommand>
  [arguments]`; `open` on a running Tafl only brings it forward and drops the arguments. (`open -n`
  would start a second copy, which runs the probe before the earlier-instance hand-over, but the
  running Tafl would hold the shortcuts `keys` tests.) A panel with a Continue button pauses the
  steps that need a human look.
- Read the log: `/usr/bin/log show --last 10m --style compact --predicate 'subsystem ==
  "com.michaelrigart.tafl" AND category == "probe"'`.

Subcommands (`[seconds]` is how long to keep logging):

- `windows [seconds]`: each observable app's windows (Accessibility and window-list ids, frames,
  what is settable), then their window notifications.
- `apply <x> <y> <w> <h> [size-first|position-first] [keep-enhanced-ui]`: after Continue, move
  the focused window to the frame (Accessibility coordinates) and log each write and read-back.
  It moves a real window.
- `raise <bundle-id> [<bundle-id> ...]`: raise each app's first window in the order given and
  make its app frontmost through Accessibility, then log the window server's order and the
  frontmost app. The last app should end on top. It reorders real windows.
- `displays`: the displays and the Dock's frame before and after you change the Dock.
- `displays-watch [seconds]`: log each display reconfiguration and window moves around it.
- `tiling [seconds]`: macOS's tiling settings, then window moves and resizes against the
  display's fractions.
- `keys [seconds]`: register every default shortcut through Carbon, shared and exclusive, log
  each result and each press, and log the keyboard layout and input source changes.
