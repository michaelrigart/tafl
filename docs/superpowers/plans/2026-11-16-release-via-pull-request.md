# Releasing Through a Pull Request (Tafl Port) Implementation Plan

**Status:** Approved

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tafl's `scripts/release` lands its release commit through a pull request it opens, checks and merges, exactly as Muninn's does, with its test and documentation to match.

**Architecture:** A port, not a reimplementation. `scripts/release` and `scripts/tests/test-release-dry-run` are Muninn's files at commit `M`, passed through the rename below; the test then keeps Tafl's own zap and changelog checks. The documentation follows Muninn's at `M`, in Tafl's words.

**Tech Stack:** bash, `gh`, git, `xcodebuild` through `scripts/release`, Python 3 (`scripts/changelog.py`, unchanged).

**Spec:** `docs/superpowers/specs/2026-11-16-release-via-pull-request-design.md` (Tafl's differences). It names the canonical design, Muninn's `docs/superpowers/specs/2026-11-16-release-via-pull-request-design.md`, which holds the behaviour. Read both.

**Source (`M`):** the commit on Muninn's `fix/release-via-pr` that passes Codex's pre-merge review. Not yet known: the run waits for it. The driver writes its full SHA here, with Muninn's suite total at `M`, before Task 1. Every command below reads two shell variables the implementer sets first: `M`, that full SHA, and `MUNINN`, the path of a Muninn checkout that has it (the driver gives both in each brief). `git cat-file -e "$M^{commit}"` in `$MUNINN` must succeed before any step runs.

## Global Constraints

- **Rename:** `sed -e 's/muninn/tafl/g' -e 's/Muninn/Tafl/g'`. Team `CX4MWR5579` and tap `michaelrigart/homebrew-tap` are the same in both repositories and need no change.
- **Allowed differences** in `scripts/tests/test-release-dry-run` after the rename, and no others: Tafl's zap and cask assertions instead of Muninn's `zap_is_settings_only` and its four cases; the "section holds only the fixture's text" case names Tafl's entry `Tafl v1: place windows on a grid`. `scripts/release` has none.
- **Muninn is read-only:** read `M` with `git -C "$MUNINN" show "$M:<path>"`; never edit, commit, check out or fetch in `$MUNINN`.
- **Port through a file:** `git show` writes to `$TMPDIR` first and `sed` runs only if it succeeded, so a failed read never empties a Tafl file.
- **Commands:** the suite and `scripts/release --dry-run` need the keychain signing identity and Xcode. Run them outside the agent sandbox, prefixed with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Never run `scripts/release` without `--dry-run`.
- **Sandbox:** process substitution (`<(...)`) fails inside the sandbox; diff through files in `$TMPDIR`.
- **No `CHANGELOG.md` entry:** nothing changes for users.
- **Commits:** implementers do not commit; the controller commits each task on its own, imperative mood, no agent attribution.
- **Public repository:** no machine-specific paths in any committed file.

## Review Focus

1. **Muninn-only content the rename makes look like Tafl's** (`~/.config/tafl`, "Tafl records calls", FluidAudio, meetings, models): Tafl's cask never names `.config`, and its changelog has none of these. Expected: none outside the allowed differences. (Task 1, Step 2.)
2. **A rename inside a link to Muninn** (a comment citing Muninn's design by URL or path) becomes a link to a Tafl file that does not exist. Expected: every `michaelrigart/tafl` URL and every `docs/` path in the ported files exists in Tafl, or the line keeps Muninn's name. (Task 1, Step 2.)
3. **Muninn's branch moves after `M`, before the merges:** Tafl takes the change too (spec, "What Tafl takes"). Expected: the port is redone from the new commit, never patched by hand. ("Re-port" below.)
4. **The dry run on this checkout with a token that cannot merge** (an agent session's `gh` token): it notes that and exits 0, creating no branch, tag, pull request or release anywhere. (Task 1, Step 8.)
5. **Documentation that still says the script pushes `main`** (AGENTS.md's "it … pushes" today). Expected: no such claim left. (Task 2, Step 4.)

---

### Task 1: Port the release script and its test

**Depends on:** none (needs `M`).

**Files:**
- Modify: `scripts/release`
- Modify: `scripts/tests/test-release-dry-run`

**Interfaces:**
- Consumes: `"$M:scripts/release"` and `"$M:scripts/tests/test-release-dry-run"` in `$MUNINN`; Tafl's zap assertions from `c654410:scripts/tests/test-release-dry-run` (the seven lines from `expect "a: the cask has exactly one zap stanza"` to `expect "a: the cask never mentions xattr"`).
- Produces: the release flow Task 2 documents. Nothing calls it from code.

- [ ] **Step 1: Port the test**

```bash
git -C "$MUNINN" show "$M:scripts/tests/test-release-dry-run" >"$TMPDIR/muninn-test" \
  && sed -e 's/muninn/tafl/g' -e 's/Muninn/Tafl/g' "$TMPDIR/muninn-test" >scripts/tests/test-release-dry-run
```

Then make the allowed differences, and only those:
- delete `zap_is_settings_only` with its comment, and the four cases that call it with their fixture files (`a: the cask zaps only the settings`, `a: an extra zap target fails`, `a: a zap list fails`, `a: a delete elsewhere fails`). Keep `rejects`: the `.noindex` cases use it;
- put Tafl's seven zap lines (Interfaces) where those cases stood;
- in `a: the section holds only the fixture's text`, replace the renamed Muninn entry with `"Tafl v1: place windows on a grid"`.

If Muninn's test at `M` no longer has these as described, stop and report to the controller.

- [ ] **Step 2: Check for content the rename got wrong**

Run: `rg -n -i 'muninn|record|meeting|FluidAudio|model|transcri|\.config|Application Support|michaelrigart/tafl/(blob|tree)|docs/' scripts/tests/test-release-dry-run`
Expected: only Tafl's `.config` assertion, and any `docs/` path or Tafl URL that exists in this repository. Report any other hit to the controller; it is a spec question, not an edit.

- [ ] **Step 3: Run the ported test against today's script (the revert check)**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/tests/test-release-dry-run`
Expected: exits non-zero, with `FAIL` lines for the pull-request cases (among them the new release landing through a pull request and the token refusals).

- [ ] **Step 4: Port the script**

```bash
git -C "$MUNINN" show "$M:scripts/release" >"$TMPDIR/muninn-release" \
  && sed -e 's/muninn/tafl/g' -e 's/Muninn/Tafl/g' "$TMPDIR/muninn-release" >scripts/release
```

Run Step 2's `rg` on `scripts/release`. Expected: no hit. The file keeps mode 755 (`git diff --summary` shows no mode change).

- [ ] **Step 5: Diff against Muninn (spec, Verification)**

```bash
for f in scripts/release scripts/tests/test-release-dry-run; do
  git -C "$MUNINN" show "$M:$f" >"$TMPDIR/source" || { echo "cannot read $M:$f"; break; }
  sed -e 's/muninn/tafl/g' -e 's/Muninn/Tafl/g' "$TMPDIR/source" >"$TMPDIR/ported"
  echo "== $f"; diff "$TMPDIR/ported" "$f"
done
```

Expected: nothing for `scripts/release`; for the test, only the hunks of Step 1.

- [ ] **Step 6: Run the suite**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/tests/test-release-dry-run`
Expected: exit 0, last line `N of N cases passed` with N = Muninn's total at `M` plus one (Muninn's four zap cases out, Tafl's five zap and cask cases in).

- [ ] **Step 7: Commit** (controller)

```bash
git add scripts/release scripts/tests/test-release-dry-run
git commit -m "Release through a pull request, as Muninn does"
```

- [ ] **Step 8: Dry run on this checkout (canonical Acceptance 2)**

Before: record `git ls-remote origin 'refs/heads/release/*' 'refs/tags/*'` and `gh pr list --repo michaelrigart/tafl --state all --limit 5 --json number`.
Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/release --dry-run`
Expected: exit 0; last line `Dry run: nothing committed, branched, pushed, merged, tagged or published.`; a note if the session's `gh` token cannot merge. After: `git status --short` empty, `git branch --list 'release/*'` empty, HEAD still on `fix/release-via-pr`, and both recorded listings unchanged.

### Task 2: Document releasing through a pull request

**Depends on:** Task 1 (documents its behaviour).

**Files:**
- Modify: `README.md` ("Releasing")
- Modify: `AGENTS.md` (the "Release" line under "Commands"; the distribution pointer under "Releases and CI")
- Modify: `docs/superpowers/specs/2026-11-06-tafl-distribution-design.md` (one line under the header)

**Interfaces:**
- Consumes: Muninn's `README.md`, `AGENTS.md` and `docs/superpowers/specs/2026-11-03-muninn-distribution-design.md` at `M`.

- [ ] **Step 1: README, "Releasing"**

Take the release paragraph(s) of Muninn's "Releasing" at `M`, renamed; keep Tafl's sentence on `design/render` as it is. It must say (canonical, Documentation): the release commit goes through a pull request the script opens and merges as admin; `gh` must use a login with the `repo` scope of an admin account; where a failed run leaves things and how `--version` resumes.

- [ ] **Step 2: AGENTS.md**

- The "Release" line: Muninn's at `M`, renamed, with Tafl's "Michael" where Muninn says "the maintainer". It says the script pushes a release branch and merges its pull request.
- The pointer under "Releases and CI" keeps the distribution design and gains the canonical design by forge link (`https://github.com/michaelrigart/muninn/blob/main/docs/superpowers/specs/2026-11-16-release-via-pull-request-design.md`) and Tafl's port spec by path. Follow Muninn's wording at `M` where it has one.

- [ ] **Step 3: Distribution design**

Add one line under its header, after **Template:**, as Muninn's distribution design at `M` does: the release flow is superseded in part by the canonical design (forge link), with Tafl's port spec by path. Change nothing else in the file.

- [ ] **Step 4: Check**

Run: `rg -n -i 'push' README.md AGENTS.md`
Expected: no line says `scripts/release` pushes `main` or pushes without naming the release branch.
Run: `git diff --stat`
Expected: exactly the three files.

- [ ] **Step 5: Commit** (controller)

```bash
git add README.md AGENTS.md docs/superpowers/specs/2026-11-06-tafl-distribution-design.md
git commit -m "Document releasing through a pull request"
```

## Final verification (controller, on the last commit)

Outside the sandbox, with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`:

- `swift test --package-path Packages/TaflCore` and `swift test --package-path Packages/TaflPlatform27`: pass.
- `/usr/bin/python3 -m unittest discover -s scripts/tests -p 'test_*.py'`, `scripts/tests/test-release-dry-run`, `scripts/tests/test-lint-tests`, `scripts/lint-tests`: pass.
- `scripts/tests/test-verify-app <Release Tafl.app> <Debug Tafl.app>`, from a Release and a Debug build into `build/dd.noindex`: pass.

Report totals as passed/total.

## Re-port

If Muninn's `fix/release-via-pr` gains commits after `M` before the merges and its pre-merge review passes again: set `M` to the new commit here, redo Task 1 Steps 1–2 and 4–6 and Task 2 Steps 1–4 from it, and commit "Take Muninn's <subject> into the release flow". Never edit the ported files by hand to follow Muninn.

## Finishing (controller)

- Push `fix/release-via-pr` and open a draft pull request (`merge-request` skill). Its body says it merges only after Muninn's pull request, and that every pull request of the change (canonical design, "Ports") is opened before any merges.
- Set the port spec's **Status** to `In progress` with the pull request; in the final pre-merge commit, `Implemented` citing it, and mark this plan completed.
- Canonical Acceptance 3 (the next real release lands, tags and publishes in one run) is Michael's, after the merge.
