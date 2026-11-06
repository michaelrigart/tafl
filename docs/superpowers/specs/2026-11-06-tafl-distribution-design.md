# Tafl build and distribution — design

**Date:** 2026-11-06
**Owner:** Michael Rigart
**Status:** In progress (branch `feat/distribution`, stacked on `feat/tafl-v1`; no pull request
yet, because the repository has no remote)
**Template:** Hulder's distribution design (`michaelrigart/hulder`,
`docs/superpowers/specs/2026-11-03-hulder-distribution-design.md`). The shared build recipe is
canonical in Muninn's (`michaelrigart/muninn`,
`docs/superpowers/specs/2026-11-03-muninn-distribution-design.md`). This document repeats what
applies to Tafl, so it can be planned on its own, and says where Tafl differs.

## Why

Michael has four macOS menu bar apps and wants them built, installed and released the same
way. Linger, Hulder and Muninn share one recipe: XcodeGen, `xcodebuild`, install into
`/Applications`, Personal Team signing, a release script, a Homebrew cask, CI, and artwork
regenerated from the designer's sources. Tafl v1 has the first steps of it but not the rest:

- it is signed ad hoc, so every rebuild needs the Accessibility permission granted again (each
  probe and live-check build so far did);
- it has no app icon: the menu bar shows an SF Symbol, and the designer's window-manager logo
  set is unused;
- it has no release script, changelog, cask, CI or README, and no remote.

Hulder is Tafl's twin in everything the recipe touches: a `Core` and a `Platform27` package,
macOS 27 only, Swift 6 with strict concurrency, no entitlements, menu bar only, a Debug-only
probe, Accessibility, and running only from `/Applications`. Tafl takes Hulder's files with the
name changed, and differs only where listed under "Allowed differences".

## Goals

- Tafl builds, installs and runs with the same commands as the other three, with only the name
  changed.
- The designer's window-manager logo set is Tafl's app icon and the source of its menu bar icon,
  integrated as in the other apps.
- `brew install --cask michaelrigart/tap/tafl` installs Tafl, and `brew upgrade` upgrades it.
- One command on Michael's Mac cuts a release, as for the others.
- The Accessibility grant survives rebuilds and upgrades.
- CI tests and builds every pull request and every push to `main`.
- Tafl's repository becomes public at `michaelrigart/tafl`.

## Non-goals

- Developer ID signing and notarization (the paid Developer Program, declined for Linger).
- Mac App Store submission, automatic updates inside the app, signing in CI, Intel Macs.
- Changing what Tafl does. v1's behaviour stays as built and reviewed on `feat/tafl-v1`; a v1
  defect found while checking this work goes to v1's branch or to Michael, and is not fixed here.
- Changing Linger, Hulder or Muninn. Tafl joins their recipe; it does not move it. The one
  exception is Muninn's CI rule (see CI), and only with Michael's go-ahead.
- Bringing anything on `feat/tafl-v1` forward that isn't needed here. v1's open items (the
  docked probe checks, the Codex convergence decision, the live checks and acceptance) stay on
  v1's branch.

## Anti-goals

- The cask must not strip the quarantine attribute or otherwise bypass Gatekeeper.
- No certificate, private key or token in the repository or in CI.
- No machine-specific paths or settings in the repository. It becomes public.
- The release script pushes to `main` only its own release commit, plus the tag. Only Michael
  runs it.
- No release contains the probe.
- Uninstalling never touches `~/.config/tafl`. The config is the user's own file, often a
  symlink into a dotfiles repository, and Tafl never writes it.

## Decisions (Michael's)

- **The same recipe as Linger, Hulder and Muninn** (2026-11-05: "Check muninn, linger and hulder
  for our build / release steps. We need them here as well. Keep things consistent between the
  apps").
- **The window-manager logo set** (`~/App-logos-v2/window-manager`) is Tafl's artwork, used as
  in the others (2026-11-05).
- **Its own branch,** `feat/distribution`, stacked on `feat/tafl-v1`, merged right after v1
  (2026-11-06).
- **A public GitHub repository** `michaelrigart/tafl`, created and pushed to as part of this
  work (2026-11-06). This is the "when Michael says so" of v1's design.
- **Signed off** on 2026-11-06.

## How it works

### Artwork

The window-manager set holds `app-icon.svg`, `mark.svg`, `mark-on-light.svg`, the rendered
`AppIcon.appiconset` and an `.icns`. Unlike Linger's and Hulder's sets, it has no menu bar
image, as Muninn's had none.

- `design/` holds the set's three SVGs as delivered.
- `Tafl/Assets.xcassets/AppIcon.appiconset` holds the set's `Contents.json` and PNGs, and
  `project.yml` sets `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`. The `.icns` and the loose
  PNGs aren't used, as in the others.
- **The menu bar icon** *(a design call, as Muninn's)*: `design/menubar.svg` is the mark drawn
  in one colour (black on transparent) for a template image, which macOS tints for a light or
  dark menu bar and for the highlighted state. The mark's front window (the red rectangle) keeps
  its shape where it overlaps the outlined panel through a transparent gap around it, so the
  four shapes still read apart in one colour. It becomes `Tafl/Assets.xcassets/TaflMenuBar.imageset`
  at 18 × 18 and 36 × 36 pixels, marked as a template.
  Michael approves a rendering of it, in a light and a dark menu bar, before it is committed.
- `StatusItemController` shows `TaflMenuBar` instead of the SF Symbol `rectangle.split.2x2`,
  with the same accessibility description. Switching the menu bar icon off works as before.
- `design/render` regenerates every PNG in `Tafl/Assets.xcassets` from `design/` (Muninn's
  script, which renders the app icon and the menu bar image). It needs `rsvg-convert` (Homebrew
  `librsvg`), checks for it and says so if it is missing. The committed PNGs stay the source of
  truth for builds.
- The README opens with `icon_128x128@2x.png`, as the others'.

### Signing

As Hulder:

- `DEVELOPMENT_TEAM` is Michael's Personal Team, `CODE_SIGN_STYLE: Manual`,
  `CODE_SIGN_IDENTITY: Apple Development`, for Debug and Release, with no provisioning profile.
  The Team ID is public: it is embedded in every signed build.
- Release builds carry no `get-task-allow` (`CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO`).
- Anyone without the certificate (CI, contributors) adds `CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=`
  to `xcodebuild` and gets an ad hoc build, which macOS treats as a new app on every rebuild.
- Scripts pick the identity by Team ID, never by the bare name `Apple Development`.
- macOS ties the Accessibility grant to the designated requirement. With the team certificate
  it names the certificate, not one build, so the grant survives rebuilds (confirmed for
  Hulder on 2026-11-03). Moving from today's ad hoc build to a team-signed one needs the grant
  once more; the old ad hoc entry may need clearing first (`tccutil reset Accessibility
  com.michaelrigart.tafl`, which Michael runs).
- The certificate's subject, the Apple ID's email, is embedded in every public release. Michael
  accepted this for Linger (2026-11-01); the same certificate signs Tafl.
- This supersedes v1's constraint "Signing. Ad-hoc, like Linger and Hulder", which went stale
  when they moved to the Personal Team. v1's design gets a `**Revised:**` line and its Signing
  bullet points here; its Decisions keep what was decided at sign-off.

### project.yml and mise.toml

- `project.yml` gains, with Hulder's values: `ARCHS: arm64`,
  `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`, `CODE_SIGN_IDENTITY: "Apple Development"`,
  `DEVELOPMENT_TEAM`, and `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO` for Release. Everything else
  already matches Hulder's, apart from the name and the packages.
- `mise.toml` pins the same tools and versions as the others: `actionlint` and `xcodegen`.
- `.github/actionlint.yaml` as the others'.

### Commands

The shared list, in this order, in `AGENTS.md` and (the user-facing ones) in the README, each
prefixed with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` unless `xcode-select -p`
already points at Xcode, and run outside any agent sandbox:

```sh
swift test --package-path Packages/TaflCore
swift test --package-path Packages/TaflPlatform27
mise exec -- xcodegen generate
xcodebuild -project Tafl.xcodeproj -scheme Tafl -configuration Debug -derivedDataPath build -quiet build
rm -rf /Applications/Tafl.app && ditto build/Build/Products/Debug/Tafl.app /Applications/Tafl.app
open /Applications/Tafl.app
```

- The Release build is the same `xcodebuild` line with `-configuration Release`; the ad hoc
  override is listed as in Hulder's `AGENTS.md`.
- Then the script tests, `scripts/verify-app`, `scripts/release` and `design/render`, worded as
  in Hulder's `AGENTS.md`.
- The stamped install build of today's `AGENTS.md` goes: a team-signed build no longer needs a
  version stamp to tell builds apart for the grant. *(A design call; the others have none.)*

### Verifying a built app

`scripts/verify-app [--team <ID>] <Tafl.app> [<version>]`, Hulder's with the name changed, used
by CI and the release script. It fails unless:

- the signature verifies (`codesign --verify --strict`);
- the entitlements are empty, so a Debug build (which carries `get-task-allow`) fails;
- `LSUIElement` is true and the bundle identifier is `com.michaelrigart.tafl`;
- the executable does not contain the probe: neither `-TaflProbe` nor a string only the probe
  has (its usage line);
- with `--team`, the `TeamIdentifier` matches; with a version, `CFBundleShortVersionString`
  equals it and `CFBundleVersion` equals its digits.

`scripts/tests/test-verify-app <Release Tafl.app> <Debug Tafl.app>` checks that it accepts the
Release build and rejects the Debug build and tampered copies, as Hulder's does.

### CI

`.github/workflows/ci.yml`, Hulder's with the name changed:

- on pull requests and pushes to `main`, `permissions: contents: read`, a concurrency group that
  cancels superseded runs, actions pinned to full commit SHAs;
- `runs-on: xcode-27`, selecting the same Xcode as the other three (27.1 today). Muninn's rule
  now covers four apps: if Tafl doesn't build or pass its tests with 27.1, all four move to the
  27.2 release candidate together. Tafl's code is not changed to suit 27.1. That move touches the
  other three repositories, so it goes to Michael before anything changes there *(a design
  call)*. This Mac has only Xcode 27.2, so the first CI run is the first 27.1 build;
- steps: the changelog tool's tests, `TaflCore` and `TaflPlatform27` tests, `xcodegen
  generate`, a Release build signed ad hoc, `scripts/verify-app`, a Debug build signed ad hoc,
  then the verifier's test.

The runner has no Accessibility grant, no displays to rearrange and no menu bar session. A test
that needs any of them is a defect in the test: fix it so it doesn't depend on the machine,
rather than skipping it in CI. If v1's suites hit this, that is a v1 defect (see Non-goals).

### Versions, changelog and releasing

As Hulder's, with the name changed:

- the version is `date +%Y%m%d-%H%M` at the start of the release, with no `v`; it is the tag, the
  release title, the asset name `Tafl-<version>.zip` and the cask's `version`. Builds outside the
  release script are `dev`, build `0` (already so in `project.yml`);
- `CHANGELOG.md` in Keep a Changelog format, with the same preamble and link definitions. The
  first `## [Unreleased]` records v1, in user-facing words, and this work;
- `scripts/release [--dry-run] [--version <YYYYMMDD-HHMM>]` and `scripts/changelog.py` come over
  from Hulder, renamed, with their tests, including resuming and recovering an unpushed release
  commit. A new release must be cut from `main`, so the first one waits until both branches
  are merged.

### Homebrew cask

`Casks/tafl.rb` in `michaelrigart/homebrew-tap`, from `scripts/tafl.rb.template`:

- `version`, `sha256`, `url` on the release asset, `name`, a generic `desc`, the repository as
  `homepage`, `livecheck` as the others;
- `depends_on arch: :arm64` and `depends_on macos:` macOS 27, with the same symbol as Hulder's
  cask;
- `app "Tafl.app", target: "/Applications/Tafl.app"`, as Hulder's: Tafl runs only from
  `/Applications`;
- `uninstall quit: "com.michaelrigart.tafl"`;
- `zap` removes `~/.local/state/tafl` (the window memory) and
  `~/Library/Preferences/com.michaelrigart.tafl.plist` (AppKit's defaults, such as the menu bar
  icon's position), and never `~/.config/tafl` *(a design call; see Anti-goals)*;
- `caveats`:
  - "Open Anyway" in System Settings › Privacy & Security, because the app isn't notarized;
  - the Accessibility grant, through Tafl's onboarding window;
  - quit Rectangle (or another window manager with the same shortcuts) first: Tafl takes the
    shortcuts it registers, and a shortcut another app holds gives no error (measured on 27.2,
    v1's Task 2).

### Documentation

- **README**, in Hulder's shape and order: what Tafl does, Features, Requirements (macOS 27,
  Apple silicon; Xcode 27 and mise to build), Install (Homebrew, the first-run steps, Rectangle),
  Build and install (the shared block, Release with the ad hoc override), Tests, Probe (Debug
  only; `AGENTS.md` lists the subcommands), Releasing, Limitations (from v1's design and its
  27.2 measurements), Design (links to v1's design and this one), License (MIT, with Rectangle's
  notice). No details about Michael's machine.
- **AGENTS.md:** the command list above; a "Releases and CI" section as Hulder's; and the rules
  an agent gets wrong, with the signing rule replaced by Hulder's (team-signed builds keep the
  grant; ad hoc builds need it again after every rebuild; moving from ad hoc to team-signed
  needs it once). Tafl's other rules stay.
- **v1's design:** the `**Revised:**` line and the Signing bullet (see Signing). The Distribution
  non-goal there (automatic updates, localisation, the App Store) still holds.

### Going public

Before the first push, the tracked files and the whole history of both branches are checked for
secrets and private content (credentials, tokens, personal data, the content of local files).
The push guard's gitleaks scan runs on every push as well. Anything that must go from history is
brought to Michael before anything is pushed: rewriting history is his call. A scan on
2026-11-06 found none. What it did find stays, as in the other three public repositories: v1's
design names the checkout (`~/Code/tafl`) and `chezmoi`, and test fixtures use home-directory
paths such as `/Users/michael/.config/tafl/config.toml` to test path redaction.

Then, in this order:

1. create the public repository `michaelrigart/tafl` with `gh`, and add it as `origin`;
2. push `main`, `feat/tafl-v1` and `feat/distribution`;
3. open v1's draft pull request (`feat/tafl-v1` into `main`) and this one (`feat/distribution`
   into `feat/tafl-v1`), and record each in its design's Status.

GitHub retargets a stacked pull request only when its base branch is deleted, and the four
repositories keep merged branches. So after v1 merges, this branch is rebased onto `main` and its
pull request retargeted with `gh pr edit --base main` before it can merge; otherwise it would
land on `feat/tafl-v1`.

CI runs on this branch's pull request only: `feat/tafl-v1` and `main` have no workflow yet.

## Allowed differences

Apart from the name, the build steps read as Hulder's. These differences stay:

| | Tafl | Hulder |
|---|---|---|
| Packages | `TaflCore`, `TaflPlatform27` | `HulderCore`, `HulderPlatform27` |
| Probe marker in `verify-app` | `-TaflProbe` and the probe's usage line | `-HulderProbe` and its usage line |
| Menu bar art | drawn from the mark (`design/menubar.svg`), rendered by `design/render` | from the logo set |
| `zap` | `~/.local/state/tafl` and the preferences file | Application Support and the preferences file |
| Cask caveats | Accessibility, Rectangle | Device Control, the menu bar folder |

## Constraints

- Pushes from Michael's Mac use his existing git and `gh` credentials.
- The Personal Team certificate and Apple's WWDR G3 intermediate are already in Michael's login
  keychain for the other three.
- `feat/tafl-v1` keeps moving while this branch is open (v1's Task 2 Step 6 edits v1's design and
  `AGENTS.md`). This branch rebases onto it before review and again before merge; conflicts in
  v1's design header and in `AGENTS.md` are expected and resolved by keeping both changes.
- `/Applications/Tafl.app` is v1's probe build, granted for tomorrow's docked checks. This work
  doesn't install over it until those checks are done; the signing acceptance below runs after
  them.

## Delivery

- **Branch:** `feat/distribution` in the `wt` checkout `~/Code/tafl-feat-distribution`, stacked on
  `feat/tafl-v1`.
- **Pull requests:** v1's and this one open together (see Going public); v1's merges first, then
  this one.

## Acceptance

1. CI passes on this branch's pull request: both suites, the Release build, the verifier and the
   verifier's test.
2. **Michael checks, on a team-signed Debug build installed into `/Applications`** (after v1's
   docked probe checks): he grants Accessibility once; after quitting, a rebuild and reinstall,
   and relaunching with `open`, Tafl is still trusted (Settings › Permissions shows it, and a
   shortcut moves a window) and launch at login is still on.
3. The menu bar icon shows in a light and a dark menu bar, tints when highlighted, and can still
   be switched off.
4. `scripts/release --dry-run` builds, verifies and packages an Apple silicon zip, and prints the
   changelog section it would commit.
5. The README's build-from-source block, run as written with the ad hoc override, produces an app
   that launches into onboarding.
6. **After both merges,** the first real release creates the tag, the GitHub release with the zip,
   and the cask. Then `brew install --cask michaelrigart/tap/tafl` installs Tafl into
   `/Applications`, and after "Open Anyway" and the grant it launches and places a window.
7. **At the second release,** after `brew upgrade`, Tafl doesn't ask for Accessibility again.
   Whether the upgrade launches without "Open Anyway" is recorded; if it doesn't, the caveats and
   the README say so.

**A failed persistence check** (in 2 or 7, the grant asked for again) fails acceptance and goes to
Michael, because it means a goal can't be met as designed. Documentation never stands in for it.
Only the "Open Anyway" outcome may be documented instead.

## Left to the builder

- the exact menu bar drawing within "Artwork", for Michael's approval;
- how the work splits into commits;
- the README, caveat and changelog wording;
- the pinned action versions and the exact Xcode on the runner, within Muninn's rule;
- the probe's marker strings, as long as Debug builds contain them and Release builds don't.
