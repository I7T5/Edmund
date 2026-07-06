---
name: edmund-change-control
description: >
  How changes are classified, gated, and reviewed in the Edmund repo. Load at
  the START of any task that will modify the repo; before committing, branching,
  or proposing a merge or release; when deciding whether a change needs a test,
  a screencapture visual check, or a live repro; when unsure what requires
  explicitly asking the maintainer (push, PR, merge, release, deleting
  uncommitted work, touching test-files/, adding dependencies). Contains the
  non-negotiable rules with the historical incident behind each one.
---

# Edmund change control

Last verified: 2026-07-05, against `main` @ fe8a1f5 (release 0.1.3).

This is the gatekeeping doc: what class of change you are making, which gate it
must pass, and the rules that are never traded away. The rules exist because
each was paid for — the incident column is not decoration.

## 0. Before you start (task setup)

```
[ ] Read docs/ARCHITECTURE.md before any non-trivial change (its own rule)
[ ] git status — note any uncommitted work; never clobber it
[ ] Not on main? Fine. On main? Branch NOW, before the first edit
[ ] Classify the change (§1) so you know the gate before you write code
[ ] Edit-pipeline / selection work? Plan the live repro FIRST — if you can't
    reproduce the bug, you can't prove the fix (§3, last row)
```

## 1. Classify the change, apply the gate

Classify FIRST, before writing code. The class decides the verification bar.

| Class | Examples | Gate before commit |
|---|---|---|
| Docs-only | ARCHITECTURE.md, README, docs/*.md, comments | None beyond review. `swift test` still runs as a Stop hook; ignore no failures it surfaces. |
| Code (logic) change | Parser, block model, helpers, non-drawing refactor | `swift test` green. New behavior or bug fix → add a test that fails without the change. |
| Visually-drawing change | Anything in `Rendering/`, overlays, decorations, padding, fonts, layout fragments | All of the above, PLUS build the app and `screencapture` the result (window-by-id method — see `edmund-live-repro-and-diagnostics`). Headless layout is not proof for anything that draws. |
| Edit-pipeline / selection behavior | `+EditFlow`, `+Composition`, `+SelectionTracking`, `+Undo`, caret, IME, drag, viewport timing | All of the above, PLUS a live repro or soak script (`-debug.reproScript`, see `edmund-caret-integrity-campaign` and `docs/live-repro-guide.md`). Headless tests cannot exercise deferred AppKit machinery — the queued selection fixup, drag paths, IME. Rounds 1–5 of delete-drift shipped on tests + reasoning; all recurred. |
| Release | Version bump, tag, appcast | Run `misc/before-you-release.md` top to bottom, then `misc/how-to-release.md`. See `edmund-release-and-operate`. Never start a release without being asked. |

Notes on the gates:

- `swift test` (~750+ tests, ~10s) also runs automatically as a **Stop hook**
  (`.claude/settings.json`: `swift test 2>&1 | tail -5`) at the end of every
  turn. That is a safety net, not the gate — run it yourself before committing
  so the failure is yours to see, not the hook's.
- A change can be in multiple classes. Apply the union of gates. A caret fix
  that also moves a decoration needs test + screencapture + live repro.
- "Draws" is broad: padding, insets, colors, wrapping, fragment frames. If a
  human could see the diff, screenshot it.

Classification edge cases that have gone wrong before:

- "It's just an attribute change" is NOT automatically the code-logic class.
  If the attributes change measured geometry (font size, paragraph spacing,
  hidden-delimiter width), it draws AND it needs `invalidateLayout(for:)` —
  see §3.
- "It's just a restyle helper" that runs `beginEditing`/`setAttributes` on
  storage is edit-pipeline class if it can fire during IME composition or
  after a bypassed edit. When in doubt, grep for `hasMarkedText` guards on
  the sibling paths and match them.
- A test-only change is docs-class for gating purposes (nothing to screenshot),
  but the Stop hook still must pass — a broken test is a broken commit.
- Release-adjacent edits (`Info.plist` versions, `CHANGELOG.md`, `appcast.xml`,
  `scripts/release.sh`, `.github/workflows/`) are release class even when tiny.
  The v0.1.0→0.1.1 Sparkle failure came from the build script's signing step,
  not from app code.

## 2. Git discipline

From CLAUDE.md + ARCHITECTURE §12 + the repo's own history (`git branch -a`).

- **Branch off `main` for every fix. Never commit straight to `main`.**
  One feature/fix per branch.
- Branch prefixes actually in use (verified): `fix/`, `feat/`, `feature/`,
  `docs/`, `chore/`, `uiux/`, `ui/`, `ux/`, `markdown/`, `bug/`, `refactor/`,
  `ci/`, `release/`. Prefer `fix/`, `feat/`, `docs/`, `chore/` for new work;
  `uiux/` for visual polish; `markdown/` for syntax-feature work.
- **Small, logical commits; commit frequently.** A commit that mixes the fix
  with a drive-by refactor is two commits done wrong.
- **NEVER auto-push, open a PR, or merge.** Only when the maintainer
  explicitly asks. No exceptions for "it's just docs."
- **Never discard uncommitted changes.** No `git checkout -- .`,
  `git reset --hard`, `git clean` on a dirty tree without explicit permission.
- Commit messages follow the observed style: `fix(editor): …`, `docs: …`,
  `ui: …`, `chore: …` — short imperative subject.

## 3. The non-negotiables

Each rule was established by an incident. Verify against the cited doc before
arguing an exception.

| Rule | Rationale | Incident |
|---|---|---|
| Text storage always equals `rawSource`; rendering is attribute-only. Never insert/delete display characters — hide delimiters, never strip them. | Display offset == raw offset (identity mapping) is what every selection, sync, and heal path assumes. Break it and every later edit drifts. | The delete-drift saga: six rounds over months, each recurrence traced to storage/rawSource divergence in some path. `docs/delete-drift-investigation.md`. |
| TextKit 2 only. Never touch `NSTextView.layoutManager`; never store `NSTextBlock`/`NSTextTable` attributes. | Either one **silently and permanently** reverts the view to TextKit 1. A DEBUG tripwire asserts if TK1 engages — heed it. | ARCHITECTURE §2; the tripwire exists because the reversion is otherwise invisible. |
| No `NSTextAttachment`. Images/icons are drawn as overlays. | TK2 only honors attachments on U+FFFC, which `rawSource` never contains (see rule 1). | ARCHITECTURE §2, §5. |
| Never draw images on wrapping (multi-line) fragments; use stroked `CGPath`s instead. | A TK2 image on a wrapping fragment wedges layout — collapses the fragment to one line. Shapes don't trigger it. | The callout custom-title icon: `docs/callout-title-wrap-investigation.md`; fix in ae61644 (stroked path, not image). |
| Every storage-touching styling path guards `!hasMarkedText()` — including async paths scheduled before composition began. | Mutating storage mid-IME-composition strands the marked text; `didChangeText` then bails forever on its own guard and every later edit drifts. | Delete-drift rounds 1–2 (IME stranding cascade). `docs/delete-drift-investigation.md`. |
| Never assume `didChangeText` follows every edit. Sync paths must survive a bypassed edit. | AppKit's drag-move-to-nowhere deletes via `shouldChangeText` → `replaceCharacters` and never calls `didChangeText`, silently freezing `rawSource`. The heal (`scheduleBypassedEditSyncCheck` in `+EditFlow`) exists for this. | Delete-drift round 4 (9f99795); rounds 5–6 hardened the heal itself. |
| Attribute-only restyles that change geometry must `invalidateLayout(for:)` the range. | TK2 does not re-measure on attribute change; the fragment keeps a stale frame — empty bands, clipped lines. | ARCHITECTURE §8; `recomposeDirty` and the idle drain already do this — new paths must too. |
| Undo restore is diff-based `recomposeReplacing` — never a full `recompose`. | Full recompose resets every fragment to a TK2 height estimate; the follow-up scroll lands wrong and the viewport drifts. | Undo/redo viewport drift — one of the costliest failures here. Fixed in 5bb2b40 (`fix(undo): select + center the changed text; diff-based snapshot restore`). |
| Never blanket `pkill -x edmd`. `pgrep -x edmd` first, check start times, kill only the PID you launched. | The maintainer's daily-driver app shares the binary name. A blanket pkill kills their editor with their work in it. (ARCHITECTURE §1's `pkill -x edmd` shorthand predates this rule — don't copy it.) | Established after the maintainer's own instance was killed during a debugging session. |
| Never request macOS Computer Access (Screen Recording / Accessibility). | Both are already granted to the tools you use. Requesting again re-prompts the maintainer and can wedge TCC state. | CLAUDE.md "Environment"; the `-debug.reproScript` driver exists precisely so repros need no new TCC grants. |
| Visual judgments ("balance the padding", "is it centered") are MEASURED from screencapture pixels, not eyeballed. | Eyeballed "looks right" repeatedly shipped asymmetric spacing. Crop the window, count pixels, state the numbers. | Maintainer's explicit rule from UI-polish rounds (status-bar / table-padding branches). |
| Files in `test-files/` are the maintainer's manual test corpus. Never rewrite them for automation; `test-files/todo.md` especially is owner-edited. | They encode the maintainer's by-hand regression walk. Automation churn destroys that. Create your own fixtures in a scratch dir or `Tests/`. | Standing maintainer rule. |
| Never ship a fix for a live-input-layer bug (caret, IME, drag, selection timing) on reasoning alone. A frozen repro script must falsify the bug before and confirm the fix after. | This bug class does not reproduce headless (the test harness runs TK2's queued fixup synchronously). Reasoning about deferred AppKit machinery has a ~0% shipping record here. | Delete-drift rounds 1–5 each shipped a plausible fix; each came back. Round 6 finally held because the ReproScript driver reproduced the drift deterministically first. `docs/live-repro-guide.md`. |

### The two incidents that shaped this table

Worth knowing as stories, because the rules read as pedantry until you see
the cost:

- **Delete-drift (six rounds).** The hardest live problem this repo has had.
  A caret that drifted after deletes. Round 1 blamed IME stranding — plausible
  fix, shipped, recurred. Round 2 disabled remaining marked-text sources —
  recurred. Round 3 stopped guessing and built diagnostics (selection tracing,
  event logs). Round 4's diagnostics caught a drag-move deleting storage with
  no `didChangeText` — the heal was born. Round 5: the heal itself leaped the
  caret via a stale selection. Round 6 found the actual drift mechanism —
  TextKit 2's queued `_fixSelectionAfterChange` firing at the *next*
  `endEditing` — and held only because the ReproScript driver could replay the
  exact keystroke sequence deterministically. Five shipped fixes failed; the
  one preceded by a frozen repro stuck. That asymmetry IS the change-control
  policy for this bug class.
- **Undo/redo viewport drift.** Undo restored a snapshot via full `recompose`,
  which reset every fragment to a TK2 height estimate; the follow-up
  scroll-to-caret then landed wrong and the viewport jumped. The fix (5bb2b40)
  diffs the snapshot against current text and applies only the changed span
  with `recomposeReplacing`. Moral: in TK2, layout state is part of the
  document state you must preserve — "re-render everything" is never the safe
  fallback here, it is the bug.

## 4. Review expectations

- **ARCHITECTURE.md is updated in the same PR** whenever you learn something
  non-obvious or change an invariant. The doc's own header demands this; the
  gotchas in §8 all arrived this way.
- **Quirks are documented as comments at the code site** — the edge case, the
  workaround, the *why*. Not in commit messages, not in CLAUDE.md.
- **New known issues** go in ARCHITECTURE §9 with a one-line repro and a
  pointer to any deeper write-up in `docs/`.
- Big investigations (multi-round bugs) get a `docs/*-investigation.md`
  chronicle — see `edmund-failure-archaeology` for the pattern.

## 5. Pre-commit checklist (copy-paste)

The workflow that worked (ARCHITECTURE §12 + CLAUDE.md). Run it verbatim:

```
[ ] swift test — all green (also enforced by the Stop hook; don't rely on it)
[ ] New behavior / bug fix → a test exists that fails without the change
[ ] Draws anything? → build app, screencapture window-by-id, look at the PNG
[ ] Edit-pipeline / selection change? → live repro or soak script passed
[ ] On a branch off main (fix/…, feat/…, docs/…, chore/…), NOT on main
[ ] Diff touches only what the task needs; style matches surroundings
[ ] Learned something non-obvious? → ARCHITECTURE.md updated in this change
[ ] Quirk introduced/found? → comment at the code site
[ ] Commit is small and logical; message matches repo style (fix(scope): …)
[ ] NOT pushing, NOT opening a PR, NOT merging (unless explicitly asked)
```

## 6. Ask the maintainer first — always

Never do these unprompted; ask and wait for an explicit yes:

| Action | Why it's gated |
|---|---|
| `git push`, opening a PR, merging anything | Standing rule in CLAUDE.md ("Never auto-push, PR, or merge"). The maintainer reviews and merges. |
| Starting or tagging a release | A tag push fires CI, builds, signs, publishes a GitHub Release, and updates the appcast that live users poll. Not reversible quietly. |
| Deleting anything uncommitted (files, stashes, working-tree changes) | "Never delete uncommitted changes" — the maintainer's in-progress work may be in the tree. |
| Editing anything in `test-files/` | Manual test corpus; `todo.md` there is owner-edited. Make fixtures elsewhere. |
| Adding a dependency | Current set is deliberately three (`swift-markdown`, `SwiftMath`, `Sparkle`); each new one is a codesign/bundle/update-pipeline liability (see the SwiftMath bundle saga, ARCHITECTURE §8). |
| Changing `.claude/settings.json` hooks or permissions | Alters what runs automatically on the maintainer's machine. |

## When NOT to use this skill

| You need… | Go to |
|---|---|
| The invariants' full technical statement and render pipeline | `edmund-architecture-contract` |
| To debug a failure, read traces/logs | `edmund-debugging-playbook` |
| The history of a past incident in depth | `edmund-failure-archaeology` |
| TextKit 2 / AppKit API behavior details | `textkit2-appkit-reference` |
| Launch flags, debug bundle, settings | `edmund-config-and-flags` |
| Build issues, stale binaries, environment | `edmund-build-and-env` |
| Executing a release / operating the app | `edmund-release-and-operate` |
| The screencapture / ReproScript mechanics | `edmund-live-repro-and-diagnostics` |
| Test-writing patterns and QA strategy | `edmund-validation-and-qa` |
| Writing docs / chronicles | `edmund-docs-and-writing` |
| Caret/selection bug-class specifics | `edmund-caret-integrity-campaign` |

## Provenance and maintenance

- Sources: `CLAUDE.md` (repo root), `docs/ARCHITECTURE.md` §1 §2 §8 §9 §12,
  `.claude/settings.json` (Stop hook), `misc/before-you-release.md`,
  `misc/how-to-release.md`, `docs/delete-drift-investigation.md` (rounds 1–6),
  `docs/callout-title-wrap-investigation.md`, `git log` / `git branch -a` as of
  fe8a1f5 (2026-07-05).
- Commits cited were verified in `git log`: 5bb2b40 (diff-based undo restore),
  9f99795 (round-4 heal), ae61644 (stroked-path callout icon), 1b1420a
  (round-6 caret re-assert).
- Two rules rest on maintainer statements rather than repo docs: the
  measure-from-pixels rule and the `test-files/` ownership rule. If either gets
  written into ARCHITECTURE.md, point at it here.
- Maintain: when a new incident produces a new rule, add a row to §3 with the
  incident pointer in the same PR that adds the rule to ARCHITECTURE.md. When
  the Stop hook in `.claude/settings.json` changes, update §1's note.
