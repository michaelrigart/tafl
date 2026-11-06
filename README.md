<img src="Tafl/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="128" alt="">

# Tafl

Tafl is a macOS menu bar app that places windows on a grid from the keyboard: halves,
quarters, thirds, two-thirds, maximize and more, on one display or across several. Its
settings live in one TOML file, `~/.config/tafl/config.toml`, which Tafl reloads as soon as
it changes. Tafl never writes that file, apart from a starter file you ask for when there is
none. Layouts in that file put your windows in place when a set of
displays connects.

## Features

- Placements: left, right, top and bottom halves, the four quarters, thirds and two-thirds,
  maximize, maximize height, center, larger, smaller, and restore, which returns a window to
  the frame it had before Tafl's latest run of placements on it. Thirds follow a display's
  orientation, so on a portrait display they are rows.
- Display moves: to the display on the left, right, above or below, or to the one under the
  pointer. A window keeps its placement when it moves.
- Repeats: the `repeat` setting chooses what repeating a placement does. By default,
  repeating left half or right half moves the window to the other display in that
  direction, and other placements don't repeat. It can instead cycle a half's size, or do
  nothing.
- Display changes: when the set of connected displays changes and settles, Tafl puts windows
  where its fixed rules say, and waking from sleep moves nothing.
- Layouts: named in the config file, each with an optional set of displays that applies it
  automatically and an optional shortcut. While a layout is active, new windows of its apps
  go to their place. A window you move after a layout placed it is never put back.
- Default shortcuts are Rectangle's alternate set (⌃⌥ with the arrow keys, U, I, J, K, D, F,
  G, E, R, T and more), plus display moves on ⌃⌥⌘. Any of them can be changed or unbound in
  the config file.
- A config file that fails to parse or validate is rejected as a whole: Tafl keeps the last
  good configuration and shows the error with its line. Unknown keys are errors.
- A Settings window that shows the configuration in plain language: the file's status,
  every shortcut, the layouts, the connected displays and the names to use for them, and
  whether macOS's own tiling is on. It can copy a layout snippet of the current arrangement.
  It never edits the file.
- A short overlay says why when an action fails.
- Launches at login (set in the config file). The menu bar icon can be switched off there
  too.

## Requirements

- macOS 27 or later, on Apple silicon.
- Tafl must run from `/Applications`.
- The Accessibility permission, which is how Tafl reads and moves other apps' windows. Tafl
  asks for no other permission.
- To build: Xcode 27 and [mise](https://mise.jdx.dev) for XcodeGen.

## Install

```sh
brew install --cask michaelrigart/tap/tafl
```

The cask installs Tafl to `/Applications/Tafl.app`, whatever `--appdir` says.

Tafl is signed with a free developer certificate and is not notarized, so macOS blocks it
the first time you open it. After the first install:

1. Open System Settings > Privacy & Security, find the message about Tafl and click
   **Open Anyway**.
2. Allow Tafl under Privacy & Security > Accessibility. Tafl's onboarding window opens that
   page; **Check Again** picks up the permission.
3. Quit Rectangle, or any other app that uses the same shortcuts, before you start Tafl.
   Tafl's defaults are Rectangle's alternate set, so both would register the same keys. If
   another app holds a shortcut, Tafl gets no error when it registers the same key
   (measured on macOS 27.2), so the shortcut may not reach Tafl.

Without a config file Tafl runs on its built-in defaults. Settings > Overview can create a
starter file with every setting at its default, commented. That is the only time Tafl writes
the file, and it never overwrites one.

Upgrade with `brew upgrade --cask tafl`. Releases are signed with the same certificate, and
macOS ties the Accessibility permission to that certificate, so an upgrade should keep the
permission and launch at login. For [Hulder](https://github.com/michaelrigart/hulder), the
same kind of app signed the same way, rebuilds signed with the same certificate were checked
to keep the permission; upgrades were not, and for Tafl neither has been checked yet. Whether an upgrade
needs **Open Anyway** again has not been checked either; if macOS blocks it, repeat step 1.

The developer certificate is renewed every year. Whether a renewed certificate keeps the
permission has not been confirmed; if macOS asks again after a renewal, repeat the steps.

If you built Tafl yourself before, quit it and delete every copy first, including the build
in your checkout's `build/`. Then run `tccutil reset Accessibility com.michaelrigart.tafl`,
or remove Tafl from the Accessibility list. A build signed differently from the Homebrew one
has an old entry that stays in the list and can look switched on while it no longer applies.
Moving from an ad hoc build to a signed one needs the Accessibility permission given once
more.

`brew uninstall --cask tafl` keeps `~/.config/tafl/config.toml`. It is your file, often a
symlink into a dotfiles repository, and neither uninstalling nor `--zap` removes it. `--zap`
also removes Tafl's window memory (`~/.local/state/tafl`) and its preferences.

## Build and install

To build it yourself, you need the full Xcode. If `xcode-select -p` points at the Command
Line Tools, prefix the `xcodebuild` and `swift` commands with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

The project is set up to sign with the maintainer's certificate, which you won't have.
Add `CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=` to `xcodebuild` to sign ad hoc instead.

```sh
mise trust mise.toml
mise exec -- xcodegen generate
xcodebuild -project Tafl.xcodeproj -scheme Tafl -configuration Release -derivedDataPath build CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= -quiet build
rm -rf /Applications/Tafl.app
ditto build/Build/Products/Release/Tafl.app /Applications/Tafl.app
open /Applications/Tafl.app
```

Remove the old app first: `ditto` merges into an existing bundle and would keep stale
files. Quit Tafl before you replace it, so that `open` starts the new build instead of
bringing the old one forward.

Placing windows works with an ad hoc signature. Start Tafl with `open` or Finder: launched
from a terminal, macOS gives the Accessibility permission to the terminal. A first launch
opens the onboarding window.

An ad hoc build is a different app to macOS every time you rebuild it, so you need to give
the Accessibility permission again, and the old build's entry stays in the list without
working. Run `tccutil reset Accessibility com.michaelrigart.tafl` to clear it, then allow
Tafl again.

Builds made without the override are signed with the maintainer's certificate and should
keep the permission across rebuilds, because macOS ties the permission to the certificate
(confirmed for Hulder; not yet checked for Tafl).

A build made without a version shows `dev` as its version.

## Tests

```sh
swift test --package-path Packages/TaflCore
swift test --package-path Packages/TaflPlatform27
/usr/bin/python3 -m unittest discover -s scripts/tests -p 'test_*.py'
```

The last line tests the changelog tool.

## Probe

A Debug build includes a probe that exercises the platform code Tafl ships, so a new macOS
can be checked by rerunning it. Release builds do not contain it: `scripts/verify-app` fails
a build that does. Build Debug, install it to `/Applications`, then run for example:

```sh
xcodebuild -project Tafl.xcodeproj -scheme Tafl -configuration Debug -derivedDataPath build CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= -quiet build
rm -rf /Applications/Tafl.app
ditto build/Build/Products/Debug/Tafl.app /Applications/Tafl.app
open /Applications/Tafl.app --args -TaflProbe windows
```

`AGENTS.md` lists the subcommands. The probe quits when it finishes. `apply` moves a window
you pick.

## Releasing

The maintainer cuts a release with `scripts/release`. It needs the signing certificate, so
it runs on the maintainer's Mac, not in CI. It sets the version (the time it starts,
`YYYYMMDD-HHMM`), moves the `Unreleased` entries of `CHANGELOG.md` into that version,
builds, signs, runs `scripts/verify-app`, packages `Tafl-<version>.zip`, tags, publishes
the GitHub release and updates the cask. `scripts/release --dry-run` does everything up to
the package and prints the changelog section; `--version <version>` resumes a release that
failed part way. `design/render` regenerates the app icon from `design/app-icon.svg` and the
menu bar icon from `design/menubar.svg`, and needs `rsvg-convert` (Homebrew `librsvg`).

## Limitations

Most of these come from macOS 27, not from Tafl. v1's design takes what macOS allows from
Rectangle's source and Apple's documentation; the only item below that has been measured on
macOS 27.2 is the first one.

- **A shortcut another app holds may not reach Tafl, and Tafl isn't told.** Registering a
  key another app already holds gives Tafl no error (measured on 27.2). Where the key press
  goes was not recorded, so quit Rectangle or any other app that uses the same keys.
- **No Spaces.** macOS has no public API for them, so Tafl doesn't move windows between
  Spaces and has no per-Space layouts. Layouts and display-change rules reach the windows
  of the current Space; windows on other Spaces stay where macOS put them.
- **Dragging is left to macOS's tiling.** Tafl has no drag-to-snap of its own and never
  changes macOS's tiling settings. Drag tiling works only while it is on in System
  Settings, and Settings shows its state. A window macOS tiled is recognised as placed.
- **An app can answer slowly, or not at all.** Every Accessibility call has a timeout, and
  an app that doesn't answer fails the action with "<App> didn't respond". Some apps
  refuse to deliver window events. Shortcuts and a layout applied by shortcut or from the
  menu still work on their windows, but the display-change rules and an active layout leave
  them alone.
- **An app can refuse a size.** macOS clamps a window to its display, and some apps set a
  minimum or step size. Tafl retries once within a fixed sequence, aligns the window to the
  edges it shares with its target, and the overlay says the app kept its own size.
- **Full-screen windows and sheets aren't placed.** The overlay says why.
- **Putting windows back after a display change depends on events macOS doesn't
  promise.** macOS gives no reliable notice before a display disconnects and moves the
  windows itself. Tafl keeps each window's last-known frame for each set of displays and
  acts after the change settles. v1's design lists the order of those events on macOS 27.2
  as still to be checked.
- **A private macOS call identifies windows.** If a macOS release removes it, Tafl falls
  back to matching windows by process and frame, and Settings says so.
- **Layouts never launch apps.** An entry for an app that isn't running is skipped.
- **The config file is yours to edit.** Tafl never writes it, apart from a starter file you
  ask for when there is none, and Settings only shows it.
- **What v1 leaves out:** animation, gestures, nudging and width- or height-only resizes,
  grids beyond the named placements, per-app rules outside layouts, a URL scheme, command
  line tool, AppleScript or Shortcuts, Stage Manager awareness (Tafl ignores its strip),
  automatic updates, localisation (English only), the Mac App Store, and macOS 26 and
  earlier.

## Design

- [Tafl v1](docs/superpowers/specs/2026-11-01-tafl-design.md): what macOS allows and how
  Tafl works.
- [Distribution](docs/superpowers/specs/2026-11-06-tafl-distribution-design.md): signing,
  releases, the Homebrew cask and CI.

## License

[MIT](LICENSE), with the notice of Rectangle, from which parts of Tafl are adapted.
