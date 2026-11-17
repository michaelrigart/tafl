# Releasing through a pull request (Tafl port) — design

**Date:** 2026-11-16
**Status:** Implemented — [PR #4](https://github.com/michaelrigart/tafl/pull/4)
**Canonical:** [Releasing through a pull request](https://github.com/michaelrigart/muninn/blob/main/docs/superpowers/specs/2026-11-16-release-via-pull-request-design.md)
(`michaelrigart/muninn`, `docs/superpowers/specs/2026-11-16-release-via-pull-request-design.md`,
signed off on 2026-11-16 at b87ed19 on Muninn's `fix/release-via-pr`). That document holds the
design for all five repositories. This one records only where Tafl differs.
**Supersedes in part:** Tafl's distribution design
(`docs/superpowers/specs/2026-11-06-tafl-distribution-design.md`): the same anti-goal and recovery
that the canonical design supersedes in Muninn's.

## What Tafl takes

Muninn's `scripts/release` and `scripts/tests/test-release-dry-run`, from the commit on Muninn's
`fix/release-via-pr` that passes Codex's pre-merge review, with the names changed. Michael,
2026-11-16: "all release scripts should resemble each other as much as possible". Tafl's
`scripts/release` is today identical to Muninn's apart from names, so the port copies Muninn's
files rather than reimplementing the design.

If Muninn's implementation changes after that commit, before the merges, Tafl takes the change
too.

## Differences

1. **Names:** repository `michaelrigart/tafl`, `Tafl.app`, `Tafl-<version>.zip`, the cask
   `tafl.rb` from `scripts/tafl.rb.template`, the tap commit `tafl <version>`, and the temporary
   folders `tafl-release.*` and `tafl-release-test.*`. The team (`CX4MWR5579`) and the tap
   (`michaelrigart/homebrew-tap`) are the same as Muninn's.
2. **Test checks that stay Tafl's:**
   - the cask's zap is exactly the window memory and the preferences file, and the cask never
     names `.config`, quarantine or `xattr`. Muninn's zap cases are Muninn's;
   - the dry run's changelog section lacks one of Tafl's own changelog entries, where Muninn's
     test names one of Muninn's.

   Everything else in the test is Muninn's, renamed. That includes the `.noindex` check: Tafl's
   current one, which looks only at the verified app and `build/Build`, gives way to Muninn's
   `all_inside_noindex`, which requires every `Tafl.app` under `build/` to be inside a `.noindex`
   folder and has a case that fails a build outside one.
3. **Documentation,** following the canonical "Documentation" section in Tafl's words:
   - `README.md`, "Releasing";
   - `AGENTS.md`: the release line under "Commands" and the distribution pointer under "Releases
     and CI", which gains the canonical design and this one;
   - the distribution design gains one line under its header pointing to the canonical design;
   - no `CHANGELOG.md` entry.

## Verification

As the canonical "Acceptance", plus:

- with Muninn's names changed to Tafl's, `scripts/release` shows no difference from Muninn's, and
  `scripts/tests/test-release-dry-run` shows only the differences listed above;
- the suite needs the team's signing identity, so CI does not run it. It runs on Michael's Mac,
  outside the agent sandbox, like the other commands in `AGENTS.md`.

## Delivery

- Branch `fix/release-via-pr` in `~/Code/tafl-fix-release-via-pr`, from `main` at c654410.
- All five pull requests (Muninn, Hulder, Linger, Tafl, Skald) are opened before any merges;
  Muninn's merges first.
