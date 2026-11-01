# Tafl

Design and behaviour: `docs/superpowers/specs/2026-11-01-tafl-design.md`.
Design-record rules (specs, plans, status, commits) are in the global agent instructions.

## Commands

Run all of these outside any agent sandbox: SwiftPM's nested `sandbox-exec`, the module
cache under `/var/folders` and the Xcode build service fail inside the Claude sandbox. Prefix
them with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` and don't change
`xcode-select`.

- Core tests: `swift test --package-path Packages/TaflCore`
- Platform tests: `swift test --package-path Packages/TaflPlatform27`
- Generate the project: `mise exec -- xcodegen generate` (`Tafl.xcodeproj` is not tracked)
- Build: `xcodebuild -project Tafl.xcodeproj -scheme Tafl -configuration Debug -derivedDataPath build -quiet build`
- Stamped install build: the Build command plus
  `MARKETING_VERSION=$(date +%Y%m%d-%H%M) CURRENT_PROJECT_VERSION=$(date +%Y%m%d%H%M)`
- Install: `rm -rf /Applications/Tafl.app && ditto build/Build/Products/Debug/Tafl.app /Applications/Tafl.app`
  (`ditto` merges into an existing bundle and would keep stale files)
- Run: `open /Applications/Tafl.app`

## Where code goes

- `TaflCore` imports only Foundation and TOMLDecoder (exact 0.4.5). No AppKit, SwiftUI,
  ApplicationServices, Carbon, CoreGraphics-only API, `os` or `#available`.
- Private symbols, undocumented attributes and `#available` live only in `TaflPlatform27`.
  Resolve each private symbol at run time with `dlsym`; a missing one becomes a fallback and
  a capability state, never a crash.

## Rules an agent gets wrong

- Run Tafl from `/Applications`, started with `open`. Launched from a terminal, macOS gives
  the Accessibility grant to the terminal.
- Builds are ad-hoc signed, so every rebuild needs Accessibility granted again. Michael
  clears a stale entry with `tccutil reset Accessibility com.michaelrigart.tafl`.
- A bare `log` is a zsh builtin. Use `/usr/bin/log`; the subsystem is
  `com.michaelrigart.tafl`.
- Never write `com.apple.WindowManager` or the user's config file
  (`~/.config/tafl/config.toml`).
- Never open Loop's source. Rectangle ports keep its notice in `LICENSE`.
