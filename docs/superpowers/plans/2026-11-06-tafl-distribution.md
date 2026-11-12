# Tafl Distribution Implementation Plan

**Status:** Implemented ([PR #1](https://github.com/michaelrigart/tafl/pull/1), merged into `feat/tafl-v1` on 2026-11-06; it reaches `main` with [PR #2](https://github.com/michaelrigart/tafl/pull/2)). Codex approved the plan in round 2. Completed: do not run it again; acceptance 6 and 7 follow the first releases.

**Execution notes:** Tasks 1–9 build into the shared `build/`, so only tasks that build nothing share a batch: {1, 3, 6}, then 2, 5, 7, 8 in order. Task 4 runs once Michael has approved Task 3's drawing; until then the run carries on with the others. Task 9 runs last of the build tasks. "Finishing" is the controller's, not a subagent's.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build, sign, verify, release and document Tafl with the recipe Linger, Hulder and Muninn share, give it the window-manager logo set as its icons, and publish the repository as `michaelrigart/tafl`.

**Architecture:**
- Hulder is Tafl's twin for everything here. Port its files (`michaelrigart/hulder` at `d9ab8dc`) with the name changed. A port is right when `sed -e 's/hulder/tafl/g' -e 's/Hulder/Tafl/g'` of Hulder's file differs from Tafl's only where the spec's "Allowed differences" or this plan says so.
- `design/render` is Muninn's (`michaelrigart/muninn`'s `design/render`), because it renders a menu bar image too.
- The one app change: `StatusItemController` shows the `TaflMenuBar` image instead of an SF Symbol.

**Tech Stack:** bash, Python 3 (`/usr/bin/python3`, standard library only), GitHub Actions, XcodeGen 2.46.0 and actionlint 1.7.12 through mise, Xcode 27 (27.2 here, 27.1 in CI), `rsvg-convert` (Homebrew `librsvg`), Homebrew cask DSL.

**Spec:** `docs/superpowers/specs/2026-11-06-tafl-distribution-design.md`. Read it first; then the Hulder file each task names.

## Global Constraints

- **Repository:** this repository's `feat/distribution` checkout, branch `feat/distribution`. The controller commits each task on its own, imperative mood, no agent attribution or co-author lines. Implementers never commit, push, tag, create a release or touch the tap.
- **Commands:** `swift test`, `xcodegen`, `xcodebuild`, `codesign` with the keychain identity, `security`, the script tests and `scripts/release --dry-run` run outside the agent sandbox, prefixed with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (this Mac's `xcode-select` points at the Command Line Tools; never change it).
- **Hands off the installed app:** `/Applications/Tafl.app` is v1's granted probe build for Michael's docked checks. Never install over it, launch a Tafl build (`open`), or run `tccutil`.
- **Team ID:** `CX4MWR5579`, Michael's Personal Team, the same as the other three. It is public. Pick the identity by Team ID, never by the bare name `Apple Development`.
- **Versions:** `MARKETING_VERSION` `dev` and `CURRENT_PROJECT_VERSION` `"0"` outside a release; a release is `YYYYMMDD-HHMM` with build number `YYYYMMDDHHMM`.
- **Product:** bundle identifier `com.michaelrigart.tafl`, `LSUIElement` true, empty entitlements (`Tafl/Tafl.entitlements` holds an empty dictionary), Hardened Runtime on, `ARCHS: arm64`.
- **Releases:** asset `Tafl-<version>.zip`; cask `Casks/tafl.rb` in `michaelrigart/homebrew-tap`; `app "Tafl.app", target: "/Applications/Tafl.app"`.
- **Probe markers:** `-TaflProbe` and `usage: apply <x> <y>` (from the probe's line `usage: apply <x> <y> <w> <h> [size-first|position-first] [keep-enhanced-ui]`).
- **CI:** `runs-on: xcode-27`, `sudo xcode-select -s /Applications/Xcode_27.1.app`, the same action SHAs as Hulder. If Tafl fails to build or test with 27.1, STOP and report: moving to 27.2 moves all four apps, and goes to Michael.
- **v1 is not changed here:** apart from the menu bar image, no code in `Tafl/` or `Packages/` changes. A v1 defect found on the way (a suite failing in CI included) goes to the controller, which passes it to v1's driver.
- **Public:** no machine-specific paths or settings, no certificate, key or token in any new file. The Team ID is public.

## Review Focus

1. **`brew uninstall --zap tafl`** → the window memory and AppKit's preferences go; `~/.config/tafl` (often a dotfiles symlink) stays, and nothing strips quarantine. (Task 7: assertions on the rendered cask.)
2. **A contributor without the certificate builds from the README** → the block works as written with the ad hoc override, from a fresh clone, and `scripts/verify-app` accepts the product. (Task 9.)
3. **A dark menu bar or a highlighted icon** → macOS tints the icon, because the compiled catalog marks `TaflMenuBar` as a template. (Task 4: `assetutil`.)
4. **`design/render` on a Mac without `librsvg`** → it stops before writing anything and says to install it. (Task 4.)
5. **A new public file that names this Mac** (a home path, a user name, a local checkout) → caught before going public. (Task 9's grep; Finishing's scan.)

---

### Task 1: Sign with the Personal Team, Apple silicon only

**Depends on:** none · **Tier:** sp-mechanical

**Files:**
- Modify: `project.yml` (`settings.base`, a new `settings.configs.Release`), `mise.toml`

- [ ] **Step 1: Change `project.yml`** to Hulder's settings: in `settings.base` add `ARCHS: arm64` and `DEVELOPMENT_TEAM: CX4MWR5579`, set `CODE_SIGN_IDENTITY: "Apple Development"` (was `"-"`), keep the rest, and order the keys as Hulder's (`PRODUCT_BUNDLE_IDENTIFIER` first, the rest alphabetical); add `configs: Release: CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO`. `ASSETCATALOG_COMPILER_APPICON_NAME` waits for Task 2. Add `actionlint = "1.7.12"` to `mise.toml`, above `xcodegen`, as Hulder's.
- [ ] **Step 2: Generate and build Debug and Release.** Both succeed with no provisioning profile. If signing fails, STOP and report: the spec forbids falling back to automatic signing.
- [ ] **Step 3: Check the products.**
  - `codesign -dvv` on each shows `TeamIdentifier=CX4MWR5579`.
  - `codesign -d -r-` on Release shows a designated requirement naming the team's certificate, not a `cdhash`.
  - `codesign -d --entitlements - --xml` shows none or an empty dictionary on Release, and `get-task-allow` on Debug.
  - `lipo -archs …/Contents/MacOS/Tafl` prints `arm64` for both.
- [ ] **Step 4: Check the ad hoc override.** The Release build with `CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=` signs ad hoc (`codesign -dvv` shows `Signature=adhoc`). Rebuild Release without it afterwards, so `build/` holds team-signed products for the next tasks.
- [ ] **Step 5: Commit** "Sign with the Personal Team and build for Apple silicon only".

### Task 2: The app icon

**Depends on:** Task 1 · **Tier:** sp-mechanical

**Files:**
- Create: `design/app-icon.svg`, `design/mark.svg`, `design/mark-on-light.svg`; `Tafl/Assets.xcassets/Contents.json`; `Tafl/Assets.xcassets/AppIcon.appiconset/` (`Contents.json` and its ten PNGs)
- Modify: `project.yml`

- [ ] **Step 1: Copy the set as delivered.** From the designer's window-manager logo set (delivered outside the repository): the three SVGs into `design/`, and `AppIcon.appiconset/` (its `Contents.json` and the ten `icon_*.png`) into `Tafl/Assets.xcassets/`. Not the `.icns`, `app-icon.png` or `mark.png`. `Tafl/Assets.xcassets/Contents.json` is Hulder's. `cmp` each copy against its source.
- [ ] **Step 2: Add `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`** to `settings.base`, in Hulder's position.
- [ ] **Step 3: Generate and build Debug and Release.** In each product: `Contents/Resources/AppIcon.icns` and `Assets.car` exist, and `PlistBuddy -c 'Print :CFBundleIconName'` on `Info.plist` prints `AppIcon`.
- [ ] **Step 4: Commit** "Use the window-manager logo set as the app icon".

### Task 3: Draw the menu bar icon, for Michael's approval

**Depends on:** none · **Tier:** sp-standard

Nothing in this task goes into the repository: the drawing waits in the scratchpad until Michael approves it, and a stray file would fail Task 7's clean-tree check.

**Files:**
- Create (scratchpad, `<scratch>/menubar/`): `menubar.svg`, the preview PNGs

**Interfaces:**
- Produces: `<scratch>/menubar/menubar.svg`, which Task 4 copies to `design/menubar.svg` unchanged once approved; and the absolute paths of the preview PNGs, which the controller sends to v1's driver for Michael.

- [ ] **Step 1: Draw `menubar.svg` from `design/mark.svg`** (the delivered `mark.svg` of the designer's window-manager logo set), as the spec's "Artwork" says:
  - all four shapes in one fill, `#000000`, on transparent; no other colour or opacity;
  - the front window (the red rectangle) keeps its shape and position. Where it overlaps the outlined panel, a transparent gap separates them: cut an enlarged copy of the rectangle (same corner radius plus the gap) out of the panel, with a path or a mask that `rsvg-convert` honours;
  - the gap is at least 1 px wide at 18 × 18 px, so the shapes read apart at 1x;
  - `width="1024" height="1024"` and a square `viewBox` framing the mark as Muninn's `design/menubar.svg` frames its own (the shape's bounds with a small even margin).
- [ ] **Step 2: Render the previews** with `rsvg-convert` (preview SVGs that wrap the glyph are scratch files too):
  - `menubar-18.png` and `menubar-36.png`, the sizes Task 4 commits;
  - `menubar-light.png`: a light menu bar strip (`#F2F2F2`, 48 px high, as a 24 pt bar at 2x) with the glyph drawn black at 36 px;
  - `menubar-dark.png`: the same on `#1E1E1E` with the glyph white;
  - `menubar-highlighted.png`: both strips with the item highlighted as macOS draws it (a rounded, slightly lighter or darker pill behind the glyph);
  - `menubar-zoom.png`: the 18 px rendering scaled up 8× without smoothing, to judge the gap at 1x.
- [ ] **Step 3: Report** the absolute paths of the six PNGs and the SVG, and the gap width in SVG units and in pixels at 1x. The controller messages v1's driver with the PNG paths and carries on with the other tasks.

### Task 4: The menu bar icon in the app, and `design/render`

**Depends on:** Task 2, Task 3 and Michael's approval of its drawing (a requested change goes back to Task 3 first) · **Tier:** sp-mechanical

**Files:**
- Create: `design/menubar.svg`, `design/render` (executable), `Tafl/Assets.xcassets/TaflMenuBar.imageset/` (`Contents.json`, `TaflMenuBar@1x.png`, `TaflMenuBar@2x.png`)
- Modify: `Tafl/Menu/StatusItemController.swift` (`makeItem()`)

**Interfaces:**
- Produces: `design/render [<appicon-dir> [<menubar-dir>]]`, with defaults `Tafl/Assets.xcassets/AppIcon.appiconset` and `Tafl/Assets.xcassets/TaflMenuBar.imageset`. Tasks 7 and 9 document it.

- [ ] **Step 1: Copy the approved drawing** to `design/menubar.svg`; `cmp` it against Task 3's file.
- [ ] **Step 2: Port Muninn's `design/render`** with Tafl's paths and names (`Tafl/Assets.xcassets`, `TaflMenuBar.imageset`, `TaflMenuBar@1x.png` at 18 px, `TaflMenuBar@2x.png` at 36 px). Nothing else changes.
- [ ] **Step 3: Check its refusal.** `env PATH=/usr/bin:/bin design/render <scratch>/a <scratch>/b` exits 1, prints `needs rsvg-convert (Homebrew librsvg)`, and neither directory exists afterwards.
- [ ] **Step 4: Render.** `design/render <scratch>/appicon` writes the menu bar PNGs into the real imageset and the app icon into the scratch directory, leaving the delivered app icon PNGs alone. `sips -g pixelWidth -g pixelHeight`: every scratch app icon PNG matches its slot in `AppIcon.appiconset/Contents.json`; the menu bar PNGs are 18 × 18 and 36 × 36. `git status` shows no change under `AppIcon.appiconset`.
- [ ] **Step 5: Write the imageset's `Contents.json`:** Hulder's `HulderMenuBar.imageset/Contents.json` with Tafl's file names, keeping `"template-rendering-intent": "template"`.
- [ ] **Step 6: Show the image.** In `makeItem()`, replace `NSImage(systemSymbolName: "rectangle.split.2x2", accessibilityDescription: "Tafl")` with Hulder's three lines: `NSImage(named: "TaflMenuBar")`, its `accessibilityDescription = "Tafl"`, then `item.button?.image = image`. Nothing else in the file changes; switching the icon off still removes the item.
- [ ] **Step 7: Build Debug and Release, and check the catalog.** `xcrun assetutil --info …/Contents/Resources/Assets.car` lists `TaflMenuBar` at scales 1 and 2 with template rendering, and `AppIcon`. `rg -n 'rectangle.split.2x2' Tafl` finds nothing. Both suites pass (the app code they don't cover is unchanged, which is the point).
- [ ] **Step 8: Commit** "Draw the menu bar icon from the mark" (the SVG, the imageset, the controller) and "Render the icons from their sources" (`design/render`), in that order.

### Task 5: Verify a built app

**Depends on:** Task 1 · **Tier:** sp-mechanical

**Files:**
- Create: `scripts/verify-app`, `scripts/tests/test-verify-app` (both executable)

**Interfaces:**
- Produces: `scripts/verify-app [--team <ID>] <Tafl.app> [<version>]`: exit 0 when every check passes, otherwise one `FAIL: <reason>` line per failed check and exit 1; exit 2 on bad usage. Tasks 7 and 8 call it, and `scripts/tests/test-verify-app <Release Tafl.app> <Debug Tafl.app>`.

- [ ] **Step 1: Confirm the markers.** `grep -aqF -e '-TaflProbe' build/Build/Products/Debug/Tafl.app/Contents/MacOS/Tafl` and the same for `usage: apply <x> <y>` each succeed; on the Release executable both fail. If either Debug check fails, STOP and report with the strings the Debug executable does hold.
- [ ] **Step 2: Port Hulder's `scripts/verify-app`.** Only the name, the bundle identifier and the probe patterns (the Global Constraints' markers) change.
- [ ] **Step 3: Port Hulder's `scripts/tests/test-verify-app`.** Only the names, the entitlements path `Tafl/Tafl.entitlements` and the stand-in strings change: `-TaflProbe` and `usage: apply <x> <y> <w> <h>` must fail, `probe` alone must pass. Keep every case, a to o.
- [ ] **Step 4: Run** `scripts/verify-app build/Build/Products/Release/Tafl.app` (exit 0) and `scripts/verify-app --team CX4MWR5579 build/Build/Products/Release/Tafl.app` (exit 0), then `scripts/tests/test-verify-app build/Build/Products/Release/Tafl.app build/Build/Products/Debug/Tafl.app`. Expected: `N of N cases passed`, with case n run, not skipped.
- [ ] **Step 5: Commit** "Verify built apps".

### Task 6: Changelog and its tool

**Depends on:** none · **Tier:** sp-mechanical

**Files:**
- Create: `CHANGELOG.md`, `scripts/changelog.py` (executable), `scripts/tests/test_changelog.py`

**Interfaces:**
- Produces: `scripts/changelog.py {release <version> --repo <owner/name> | notes <version> | check-unreleased} [--file <path>]`, Hulder's unchanged. Task 7 calls it.

- [ ] **Step 1: Copy Hulder's `scripts/changelog.py` unchanged** (it takes the repository as an argument), and port its test with `REPO = "michaelrigart/tafl"`.
- [ ] **Step 2: Write `CHANGELOG.md`** with Hulder's preamble, the name changed. `## [Unreleased]` holds one `### Added` list in user-facing words: Tafl v1 (placing windows on a grid and moving them between displays from the keyboard, layouts from the config file that apply themselves, a Settings window that shows the configuration, launch at login), the app and menu bar icons, installing with Homebrew, and releases signed so the Accessibility permission survives updates. The only link line is `[Unreleased]: https://github.com/michaelrigart/tafl/commits/main`, which is what `changelog.py` writes before a first release.
- [ ] **Step 3: Run** `/usr/bin/python3 -m unittest discover -s scripts/tests -p 'test_*.py'` (all pass) and `scripts/changelog.py check-unreleased` (exit 0).
- [ ] **Step 4: Commit** "Add the changelog and its tool".

### Task 7: Release script and cask template

**Depends on:** Tasks 1, 5, 6 · **Tier:** sp-standard

**Files:**
- Create: `scripts/release`, `scripts/tests/test-release-dry-run` (both executable), `scripts/tafl.rb.template`

**Interfaces:**
- Consumes: `scripts/verify-app` (Task 5), `scripts/changelog.py` (Task 6).
- Produces: `scripts/release [--dry-run] [--version <YYYYMMDD-HHMM>]`; a dry run writes `build/release/Tafl-<version>.zip` and `build/release/tafl.rb`.

- [ ] **Step 1: Port Hulder's `scripts/release` and `scripts/tests/test-release-dry-run`** with Tafl's names, project, scheme, asset, cask path and tap commit message (`tafl <version>`). Case a's check that the section holds only the fixture's text uses the opening words of Tafl's own first `Unreleased` entry.
- [ ] **Step 2: Write `scripts/tafl.rb.template`** from Hulder's `scripts/hulder.rb.template`:
  - `desc` generic and accepted by `brew style` (for example "Places windows on a grid from the keyboard");
  - `depends_on arch: :arm64`, `depends_on macos: :golden_gate`, `app "Tafl.app", target: "/Applications/Tafl.app"`, `uninstall quit: "com.michaelrigart.tafl"`, `livecheck` unchanged;
  - `zap trash:` exactly `~/.local/state/tafl` and `~/Library/Preferences/com.michaelrigart.tafl.plist`;
  - `caveats`: "Open Anyway" in System Settings › Privacy & Security, because Tafl isn't notarized; the Accessibility permission, through Tafl's onboarding window; quit Rectangle, or any app using the same shortcuts, first, because Tafl gets no error for a shortcut another app holds.
- [ ] **Step 3: Add to case a of `test-release-dry-run`,** against the rendered cask: the entries of its `zap trash:` list, read from that stanza alone, are exactly `~/.local/state/tafl` and `~/Library/Preferences/com.michaelrigart.tafl.plist`, in that order; and the whole cask contains neither `.config` nor `quarantine` nor `xattr`.
- [ ] **Step 4: Commit** "Add the release script and the cask template". `scripts/release` refuses a dirty tree even for a dry run, so this comes before Step 5.
- [ ] **Step 5: Run** `scripts/tests/test-release-dry-run` (every case passes, `brew style` included), then `scripts/release --dry-run` on this branch (acceptance 4). The dry run builds signed with the team, passes `verify-app --team CX4MWR5579 <app> <version>`, writes `Tafl-<version>.zip` and prints the changelog section. `lipo -archs` on the unpacked app prints `arm64`. Delete `build/release/` afterwards. A failure is fixed in a new commit and Step 5 runs again.

### Task 8: CI

**Depends on:** Tasks 5, 6 · **Tier:** sp-mechanical

**Files:**
- Create: `.github/workflows/ci.yml`, `.github/actionlint.yaml`

- [ ] **Step 1: Port Hulder's two files** with Tafl's package, project, scheme and product names. Everything else stays: triggers, `permissions`, `concurrency`, `timeout-minutes`, runner, Xcode, action SHAs, step order (changelog tests, `TaflCore`, `TaflPlatform27`, generate, Release ad hoc, verify, Debug ad hoc, the verifier's test).
- [ ] **Step 2: Lint:** `mise exec -- actionlint` prints nothing and exits 0.
- [ ] **Step 3: Run the workflow's steps locally,** in order, with `DEVELOPER_DIR` in place of `xcode-select` (this Mac has 27.2 only). All pass. Then rebuild Release and Debug without the override, so `build/` is team-signed again.
- [ ] **Step 4: Commit** "Run CI on the Xcode 27 image". CI runs once the pull request exists (Finishing).

### Task 9: README, AGENTS.md and v1's design

**Depends on:** Tasks 1–8 (Task 4 may still be waiting for approval; describe `design/render` as its Interfaces block does) · **Tier:** sp-standard

**Files:**
- Create: `README.md`
- Modify: `AGENTS.md`, `docs/superpowers/specs/2026-11-01-tafl-design.md` (header, Constraints › Signing)

- [ ] **Step 1: Write `README.md`** in Hulder's shape and section order, opening with `<img src="Tafl/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="128" alt="">` as Linger's does. Sections: what Tafl does; Features; Requirements (macOS 27 on Apple silicon, runs from `/Applications`, Accessibility; Xcode 27 and mise to build); Install (the cask, the first-run steps matching the caveats, Rectangle, the config at `~/.config/tafl/config.toml` that uninstalling keeps); Build and install (Hulder's text and block, with Tafl's names); Tests (both suites and the changelog tests); Probe (Debug only, `-TaflProbe`, `AGENTS.md` lists the subcommands); Releasing (Hulder's paragraph, `design/render` regenerating both icons); Limitations; Design (v1's design and this one); License (MIT, with Rectangle's notice, pointing at `LICENSE`).
  - Limitations state only facts recorded in tracked files on this branch: v1's design (its Non-goals, "What macOS allows", "Dragging") and anything marked measured on 27.2 (the shortcut another app holds). Finishing re-checks them after the rebase onto v1's measured section.
  - The grant across rebuilds and upgrades is stated as the mechanism (macOS ties it to the certificate) and as confirmed for Hulder, not as measured for Tafl, until acceptance 2 is recorded.
  - Nothing about Michael's machine: no displays, keyboard layouts, paths or apps of his.
- [ ] **Step 2: Update `AGENTS.md`:**
  - Commands: the spec's shared list in its order, with Hulder's wording for the `DEVELOPER_DIR` prefix (keeping "don't change `xcode-select`"), the Release build, the ad hoc override, the script tests, `verify-app`, `release` and `design/render`. Remove "Stamped install build".
  - Add Hulder's "Releases and CI" section, pointing at this design.
  - Rules: replace "Builds are ad-hoc signed, so every rebuild needs Accessibility granted again…" with Hulder's signing rule: team-signed builds keep the grant across rebuilds (confirmed for Hulder; for Tafl once acceptance 2 is recorded), ad hoc builds need it after every rebuild, and moving from ad hoc to team-signed needs it once, after `tccutil reset Accessibility com.michaelrigart.tafl` (which Michael runs). Every other rule stays.
- [ ] **Step 3: Revise v1's design:** under its header, `**Revised:** 2026-11-06: signing moved to Michael's Personal Team; see `docs/superpowers/specs/2026-11-06-tafl-distribution-design.md`.` Replace the Signing bullet with one stating Personal Team signing, as the other three now use, and pointing at the same design. Its Decisions stay as they are.
- [ ] **Step 4: Run the README's build block from a fresh clone.** `git clone` this checkout into the scratchpad and run the block as written, with the ad hoc override, up to and including the `xcodebuild` line (the install and `open` lines would replace v1's probe build: acceptance 5's launch stays open for Michael). `scripts/verify-app` on the product exits 0.
- [ ] **Step 5: Check for this Mac** in the working files, tracked or not (the README isn't committed yet, and `git grep` would skip it): `rg -n --hidden -e '/Users/' -e '/private/' -e 'michael@' -e '~/Code' README.md AGENTS.md CHANGELOG.md scripts design .github` finds nothing.
- [ ] **Step 6: Commit** "Document installing, building and releasing".

---

## Finishing (the controller)

1. **Cold whole-branch review** (sp-architect) of `feat/tafl-v1...feat/distribution` against the spec; fix rounds through sp-standard.
2. **Going public,** as the spec's section says:
   - scan the tracked files and the full history of `main`, `feat/tafl-v1` and `feat/distribution` with `gitleaks` and a grep for private content; anything found goes to Michael (via v1's driver) before any push;
   - `gh repo create michaelrigart/tafl --public`, then `git remote add origin git@github.com:michaelrigart/tafl.git`;
   - push `main`, then `feat/tafl-v1`, then `feat/distribution`, each in its own call;
   - v1's draft pull request (`feat/tafl-v1` into `main`) is opened by v1's driver, because its body carries v1's rulings and v1's Status edit is on v1's branch. Message the driver the moment `origin` exists, asking for that pull request and its Status update, and get back its URL;
   - open this branch's draft pull request into `feat/tafl-v1` (merge-request skill, assigned to Michael, linking v1's pull request, with "Rulings" and the open acceptance items in its body); record it in the distribution design's Status and this plan's;
   - Going public is done when both pull requests exist and both designs' Status lines name them.
3. **CI** on the pull request passes (acceptance 1). A failure with Xcode 27.1, or in a v1 suite, goes to v1's driver; this branch fixes only its own files.
4. **Rebase** onto the latest `origin/feat/tafl-v1`, keeping both sides in v1's design header and `AGENTS.md`; re-check the README's Limitations against v1's "Measured on macOS 27.2" section if it has landed; run both suites, the script tests and the Release build; push with a lease.
5. **Codex's pre-merge review** (`xreview dispatch --checkpoint pre-merge --diff origin/feat/tafl-v1...feat/distribution`), and fix rounds until it approves.

## Acceptance left open

- **2 and 3,** with Michael after v1's docked checks: a team-signed Debug build installed into `/Applications`, the grant kept across a rebuild, launch at login kept, the menu bar icon in light and dark, highlighted and switched off. A grant asked for again fails acceptance and goes to Michael. Record the results in the README, `AGENTS.md`, the caveats and this plan.
- **5's launch:** the README build installed and opened launches into onboarding, at the same time.
- **6 and 7,** after both merges: the first release, `brew install`, and the second release with `brew upgrade`.
- **After v1 merges:** rebase onto `main`, `gh pr edit --base main`, then merge. Michael runs `wt-rm feat/distribution` afterwards.

Results (2026-11-12): the grant kept across a team-signed rebuild passed on 2026-11-10 (the rebuilt 146a0b8 build started trusted), and so did the menu bar icon in a light, dark and highlighted bar. Michael skipped the rest on 2026-11-12: launch at login across a rebuild, the icon switched off, and 5's launch. 6 and 7 follow the first releases. PR #1 was merged into `feat/tafl-v1` on 2026-11-06 instead of being rebased onto `main`; Michael runs `wt-rm feat/distribution` once PR #2 is merged.
