---
name: edmund-debugging-playbook
description: >-
  Load this FIRST when any bug report or unexpected behavior arrives in Edmund:
  caret lands in the wrong place after delete/typing, viewport jumps or
  scroll-to-target misses, rendering is wrong or missing, empty bands or clipped
  lines, everything suddenly renders as plain text, app crashes or won't launch,
  a code change "doesn't take" after rebuild, undo/redo lands the viewport
  wrong, IME/CJK/accent input misbehaves, right-click shows the wrong menu,
  window grows on reopen, or a Sparkle update fails. Symptom-to-mechanism triage
  table, the traps that cost real debugging time, discriminating trace checks,
  the repro escalation ladder, and the open-bug inventory so known bugs are not
  rediscovered fresh.
---

# Edmund debugging playbook

Date-stamped 2026-07-05. Runbook for triaging any Edmund bug. Start at the
triage table, run the discriminating first check *before* forming a theory,
and check the open-bug inventory before declaring a discovery.

## When NOT to use

- Making a change, not chasing a bug → `edmund-change-control`.
- You already know the bug is live-only and need to build a deterministic
  repro → `edmund-live-repro-and-diagnostics` (full ladder detail; summary in
  §5 here).
- Caret-drift class specifically, with its six-round history →
  `edmund-caret-integrity-campaign`.
- Build/toolchain/stale-binary mechanics beyond the quick checks here →
  `edmund-build-and-env`.
- Release, signing, appcast, Sparkle pipeline → `edmund-release-and-operate`.
- TextKit 2 / AppKit API semantics reference → `textkit2-appkit-reference`.
- Launch flags and settings keys reference → `edmund-config-and-flags`.
- How past investigations were run and why → `edmund-failure-archaeology`,
  `edmund-research-methodology`.
- Pre-merge verification of a fix → `edmund-validation-and-qa`.

## 1. First 15 minutes — any new bug

Run this checklist before hypothesizing. Every step is cheap; skipping them
is how rounds 1–5 of delete-drift shipped fixes that came back.

1. **Check the open-bug inventory (§6).** If the symptom matches a known open
   bug, you are done triaging — link the backlog entry and its repro asset.
2. **Get the logs.** `ls -t ~/.edmund/logs/` and read the day's file
   (`edmund-YYYY-MM-DD.log`). Grep for the three permanent breadcrumbs:
   ```bash
   grep -n "healing storage edit that bypassed didChangeText\|repairing content above origin\|recovered stranded desync on focus regain" ~/.edmund/logs/edmund-*.log
   ```
   Also grep for `invariant:` (the always-on storage==rawSource tripwire) and
   `⚠︎LEN-MISMATCH`.
3. **Find the first bad line and walk BACKWARDS.** The user-visible symptom
   is often the second half of a two-part mechanism — the round-6 caret drift
   was armed by a silent bypass 80 seconds and dozens of healthy edits before
   the leap. Never start reading at the symptom timestamp.
4. **Rule out a stale build** if this follows a rebuild: grep
   `strings .build/arm64-apple-macosx/debug/edmd` for a long string literal
   unique to the new code (≤15-byte literals are inlined on arm64 and never
   appear); `shasum` the binary. See §3c.
5. **Check git history for prior art.** `git log --oneline -- <suspect file>`
   plus the investigation docs in `docs/`. The viewport-glitch investigation
   found four earlier fixes all working around the same unnamed root cause.
6. **Reconstruct the document.** Get the user's file or rebuild it from the
   trace's block counts/lengths. Wrapped-paragraph geometry and block kinds
   matter; do not repro against "hello world".
7. **Before touching any running app**: `pgrep -lx edmd` then
   `ps -o lstart=,command= -p <pid>`. The user's daily-driver app shares the
   binary name. Never blanket `pkill -x edmd` — kill only the PID you
   launched.
8. Row found in §2 → run its discriminating check. No row → escalate per §5,
   and add the new row here when it's understood.

## 2. The triage table

| Symptom | Likely mechanism | Discriminating first check | Where next |
|---|---|---|---|
| Caret lands blocks away after delete or typing; text itself correct | Delete-drift class: a storage edit bypassed `didChangeText` (drag-move to no valid target), or TextKit 2's queued `_fixSelectionAfterChangeInCharacterRange` fired at a later `endEditing` | `grep "healing storage edit that bypassed didChangeText" ~/.edmund/logs/edmund-*.log` and read the trace around it; look for `selectionDidChange` with `up=Y` at a surprising position | `edmund-caret-integrity-campaign`; `docs/delete-drift-investigation.md` |
| Every delete drifts, persistently, until an app switch fixes it | Stranded IME composition: `hasMarkedText()` stuck true, `didChangeText` bails forever, model frozen | Grep logs for `recovered stranded desync on focus regain`; check `storage.string == rawSource` | `docs/delete-drift-investigation.md` rounds 1–2 |
| Scroller jumps; scroll-to-target misses; content shifts on scroll | TextKit 2 height *estimates* — off-screen frames are guesses corrected as layout reaches them | Doc length vs `fullLayoutMaxLength` (100k UTF-16, `EditorTextView.swift`) — ≤100k should be fully laid out by the settle; >100k is estimate territory | `docs/viewport-glitch-investigation.md` |
| First line unreachable above the top; scroller already at 0 | TK2 strands fragments at negative y after a top-of-document edit | `grep "repairing content above origin" ~/.edmund/logs/edmund-*.log` — present means the repair fired (diagnosis confirmed, repair maybe raced); absent means a different cause | `docs/viewport-glitch-investigation.md` Bug 2 (repair unconfirmed live) |
| Undo/redo lands viewport in the wrong place; changed text not selected | Regression of the diff-based restore contract (`5bb2b40`): a full `recompose` resets every fragment to an estimate, then the scroll measures the estimates | Confirm `restoreSnapshot` still routes through range-bounded `recomposeReplacing`, never full `recompose` (`+Undo.swift`); check the changed range, not the stored caret, drives the viewport | `docs/viewport-glitch-investigation.md` Bug 1 |
| Code/visual change "doesn't take" after rebuild | STALE BUILD — SwiftPM printed `Build complete!` without relinking `edmd` | `strings .build/arm64-apple-macosx/debug/edmd \| grep "<long new literal>"`; `shasum` before/after | `edmund-build-and-env`; §3c |
| App crashes the instant any LaTeX renders | SwiftMath `*.bundle` missing from the `.app` root (its `Bundle.module` is hardcoded to `Bundle.main.bundleURL`) | `ls build/Edmund.app/*.bundle` | `scripts/build-app.sh` copy step; ARCHITECTURE §8 |
| Everything suddenly renders as plain text; all styling gone | Silent, permanent TextKit 1 reversion: an `NSLayoutManager` API was touched or an `NSTextBlock`/`NSTextTable` attribute entered storage | DEBUG builds assert via the tripwire (`textKit1FallbackTripwire`, `willSwitchToNSLayoutManagerNotification`); audit recent diffs for `layoutManager` / `NSTextBlock` | ARCHITECTURE §2; `textkit2-appkit-reference` |
| Empty bands or clipped lines after a restyle | Attribute-only change without `invalidateLayout(for:)` — TK2 keeps the stale fragment frame | Is the misbehaving path a *new* styling path? `recomposeDirty` and the idle drain already invalidate; new paths must too | ARCHITECTURE §8 |
| Weird behavior only while composing CJK / accents / emoji | A storage-touching styling path missing the `!hasMarkedText()` guard (including async work scheduled *before* composition began) | Audit the new/changed path for the guard; check logs for a persisting LEN-MISMATCH during composition | ARCHITECTURE §8; `docs/delete-drift-investigation.md` |
| Callout at end of file shows an extra colored line not prefixed by `>` | KNOWN OPEN BUG — lives in the LIVE incremental restyle path only, not static rendering (a fresh full render is clean) | Confirm against `misc/bug-repros/callout-extra-line-rendered-at-bottom.mov` | `misc/backlog.md` |
| Image leaves a large blank space below it | KNOWN OPEN BUG | `misc/bug-repros/image-blank-after.mov` | `misc/backlog.md` |
| Footnotes don't render (edit or read mode) | KNOWN OPEN BUG | — | `misc/backlog.md` |
| Right-click on the toolbar view-mode button shows "Customize Toolbar…" | `NSToolbar` with `allowsUserCustomization` claims every secondary click over the toolbar, beating view-level handlers | Verify the `DocumentWindow.sendEvent(_:)` intercept is intact (it swallows the click inside the button's bounds); note it does not cover true fullscreen | ARCHITECTURE §8 |
| Window grows by title-bar height on every reopen | Frame-vs-content-size persistence trap: saving `contentView.bounds.size` and re-applying as `contentRect` | Confirm `lastWindowSize` round-trips `window.frame.size` via `setFrame` *after* the toolbar is installed (`Document.swift`) | ARCHITECTURE §8 |
| Sparkle update fails: "The update is improperly signed and could not be validated" | Bundle not sealed: signing only the main binary leaves no `_CodeSignature/CodeResources`; or the EdDSA keypair diverged from `SUPublicEDKey` | Does `build-app.sh` still seal the whole `.app` before copying the SwiftMath bundle in? | `edmund-release-and-operate`; ARCHITECTURE §8/§13 |
| Callout/overlay icon wedges a wrapping line down to one line | TK2 image-on-multiline-fragment wedge: drawing an *image* on a wrapping fragment collapses its layout; shapes do not | Is the overlay an `NSImage` on a fragment that can wrap? Convert to a stroked `CGPath` (the custom-title callout icon fix) | `docs/callout-title-wrap-investigation.md` |
| Dragging produces no visible selection at all | Not a bug: a selection (possibly whole-document) was already active, and dragging *inside* an existing selection is AppKit's drag-*move* gesture | Trace: was there a `selectionDidChange` with a large `sel` before the drag began? | `docs/viewport-glitch-investigation.md` Bug 3 phase 1 |
| Viewport oscillates up/down during a steady drag-select | Two scroll policies fighting: drag autoscroll vs a reveal that follows the wrong end of a taller-than-viewport selection | Confirm the `scrollRangeToVisible` override still reveals the selection's *nearest* end (`+TypewriterScroll.swift`, commit `340fcbc`) | `docs/viewport-glitch-investigation.md` Bug 3 phase 2 |
| Edits do nothing at all (not drift — dropped) | `isUpdating` stuck true would make `shouldChangeText` return false | Trace shows `shouldChangeText` never returning OK; distinct from the drift signature | `+EditFlow.swift` |
| Launching via `open` shows old behavior | LaunchServices foregrounded a running instance, or ran a stale cached/translocated copy | `pgrep -lx edmd` first; launch by direct exec of the bundle binary | §3e; `edmund-build-and-env` |

## 3. The traps that cost real time

Each of these burned hours to days. Read before shipping any fix.

**(a) Shipping caret fixes on reasoning alone.** Delete-drift rounds 1–5 each
shipped a plausible, well-argued fix — and each came back. Only round 6, the
first with a frozen deterministic live repro (`bypassdelete` script), named
the actual mechanism (`_fixSelectionAfterChangeInCharacterRange` queued by a
bypassed edit, firing at the next `endEditing`) — and its first fix attempt
*failed in the repro within a minute*, which reasoning would never have
caught. Lesson: time spent making the failure cheap to observe beats time
spent reasoning about the fix. Freeze the repro before writing the fix.

**(b) Undo/redo viewport drift.** Two defects hid behind one symptom:
`restoreSnapshot` ran a full `recompose` (discarding all TK2 layout, so the
follow-up scroll measured freshly manufactured estimates) and `performUndo`
recorded the redo snapshot with the caret *at undo-invocation time*, not at
the edit. Lesson: a wrong-scroll symptom can be a geometry bug and a plain
stale-state bug stacked; fix and verify them separately. The contract since
`5bb2b40`: diff the snapshot, apply via `recomposeReplacing`, select the
changed text, let the changed range drive the viewport.

**(c) Stale binaries produce false conclusions.** In round 6, `swift build`
twice printed `Build complete!` while linking a stale `edmd` — the compile
ran, the relink silently didn't — and two "failed" fix iterations were
phantoms. Detect: grep `strings` on the binary for a *long* literal unique to
the new code. Cure: `swift package clean` (or `rm -rf .build` for release
weirdness). Never hand-delete `.build/…/edmd.build/` — that corrupts the
output-file-map and wedges the target until a full clean.

**(d) Headless-green ≠ fixed for input-layer bugs.** The round-6 unit test
reconstructs the exact document and gesture and *passes with and without the
fix*: the test harness runs AppKit's deferred selection fixup synchronously,
so the broken state never forms. A green test proves nothing about the live
NSTextView / TextKit 2 / input-context class. The scripted live repro is the
regression harness; the unit test is only a contract spec.

**(e) `open -a` runs stale cached copies.** LaunchServices can foreground an
already-running instance instead of relaunching, and can execute a stale
cached/translocated copy of the bundle — you debug last hour's code. Always
launch by direct exec: `build/Edmund.app/Contents/MacOS/edmd file.md &`
(after the §1 step-7 pgrep check).

**(f) Trusting off-screen fragment y-coordinates.** A TK2 fragment's frame is
real only once laid out; everything off-screen, plus total document height,
is an estimate. Any code that measures before ensuring layout of the
viewport↔target span lands wrong (this is Bug 1a, the typewriter-scroll
gotcha, and most historical viewport glitches). Ensure layout for the target
range first, then align to real geometry — and never verify a visual fix
from headless layout: measure from `screencapture` pixels.

## 4. Discriminating experiments — cheap checks that split hypothesis spaces

**Verbose diagnostics launch** (defaults keys are namespaced; the file must
be argv[1]):

```bash
build/Edmund.app/Contents/MacOS/edmd FILE.md \
  -settings.general.diagnosticLogging YES \
  -settings.advanced.verboseEditorDiagnostics YES
```

Or toggle in Settings ▸ Advanced ("Save diagnostic logs" + "Verbose editor
tracing"). Logs land in `~/.edmund/logs/edmund-YYYY-MM-DD.log`.

**Trace field vocabulary** (source of truth:
`Sources/EdmundCore/TextView/EditorTextView+Diagnostics.swift`,
`diagnosticState`). Every trace line ends with:

| Field | Meaning |
|---|---|
| `sel={loc,len}` | current selection |
| `active=` | active block index (or `nil`) |
| `marked=` | marked-text range, `-` if none (non-`-` outside a live composition = stranded) |
| `up=Y/N` | `isUpdating` — `Y` means the event arrived MID-RECOMPOSE |
| `undo=Y/N` | `isUndoRedoing` |
| `blocks=` | block count |
| `storLen=` / `rawLen=` | storage vs rawSource lengths |
| `⚠︎LEN-MISMATCH` | appended when they differ |

**Healthy vs suspect edit orderings:**

- Healthy: `shouldChangeText` → `selectionDidChange` (`up=N`) → `synced`.
  A *transient* `⚠︎LEN-MISMATCH` between those lines is normal (storage moves
  before rawSource syncs).
- Suspect: a `selectionDidChange` with `up=Y` at a surprising position; a
  *persisting* LEN-MISMATCH; a `shouldChangeText` with no
  `synced`/`SKIPPED`/`DEFERRED` line after it (bypassed `didChangeText`); the
  `healing storage edit that bypassed didChangeText` breadcrumb.

**`traceSelectionOrigin`**: under verbose tracing, any selection change
arriving mid-recompose (`up=Y`) or with an unconsumed pendingEdit logs a
condensed call stack naming the AppKit path that moved the caret. This is
what named `_fixSelectionAfterChangeInCharacterRange` in round 6. If your bug
moves the caret and you don't know who moved it, this answers it in one run.

**Walk backwards from the first bad line**, not forwards from the symptom.
The round-6 drift was armed 80 seconds before the visible leap. Find the
first line whose state is wrong, then read *earlier*.

**`verifyEditorInvariants`** (same file): the O(1) length check
(`storage.length != rawSource.length`) logs an `error` whenever logging is on
— no verbose toggle needed — so a hard-invariant break always leaves an
`invariant:` line. The full structural checks (string equality, blocks
reconstruct rawSource, block ranges in bounds) run under verbose tracing and
assert in DEBUG. An `invariant:` error in a user's log is a model desync,
full stop; triage as the delete-drift class.

If the existing logging didn't capture the deciding fact, add the log line
first and reproduce again — one breadcrumb beats ten speculative fixes. Keep
good ones behind `Log.shouldTrace` and ship them.

## 5. The escalation ladder (summary)

Full detail, ReproScript command reference, CGEvent driver, and soak-script
method: `edmund-live-repro-and-diagnostics` and `docs/live-repro-guide.md`.
Work down; stop at the first level that reproduces.

1. **Plain unit test** (`makeEditor()`) — model/parsing/styling logic.
2. **Windowed unit test** (NSWindow + NSScrollView, real `deleteBackward`) —
   adds layout, viewport, first-responder. **Failure to repro here is
   evidence, not defeat**: it points at deferred/queued AppKit state and at
   levels 3–4.
3. **In-process ReproScript** — DEBUG builds accept `-debug.reproScript
   <path>` (`Sources/edmd/App/ReproScript.swift`); replays a keystroke script
   through the real `window.sendEvent` path. No Accessibility/TCC needed,
   works with the window on an invisible Space. Commands: `sleep`, `caret`,
   `type`, `backspace`, `bypassdelete`, `assertcaret`, `logsel`. Launch with
   `-ApplePersistenceIgnoreState YES` and recreate the test document fresh
   each run. **The default for live bugs.**
4. **CGEvent driver** — only for paths that must originate as HID events
   (drag-select, drag-move, autoscroll). TCC decides per session; if input
   doesn't land after one test click, fall back to level 3 immediately.
5. **Instrumented field occurrence** — can't trigger it yourself: add the
   decisive breadcrumb, ask the user to enable verbose tracing, and wait. Days
   of latency; make sure the *next* occurrence is decisive.

After a fix: freeze the repro script, run a soak (several trigger cycles in
one app run with `assertcaret` checks), then full `swift test`.

## 6. Open-bug inventory

Known open bugs — check here before "discovering" one. Sources:
`misc/backlog.md` (authoritative list) and `docs/ROADMAP.md` (larger themes,
e.g. "TextKit 2 viewport stabilization" is a v1.0.0 item — viewport estimate
glitches are a known, partially-mitigated class). All entries below are OPEN
as of 2026-07-05.

| Bug | Status | Repro asset |
|---|---|---|
| Delete caret drift (class) | Open as a class; rounds 1–6 fixed, watching for round 7 | `misc/bug-repros/delete-caret-drift-{1.mp4,2.mov,3.mov,4.mov}` + matching logs |
| Inaccurate viewport estimates & related | Open class; small-doc mitigations shipped, Bug-2 repair unconfirmed live | — |
| Callout as last element renders an extra colored line | Open; live incremental restyle path only, NOT static rendering | `misc/bug-repros/callout-extra-line-rendered-at-bottom.mov` |
| Image creates large empty space below | Open | `misc/bug-repros/image-blank-after.mov` |
| Footnotes don't render (edit or read mode) | Open | — |
| Math environments don't render in read mode | Open | `misc/bug-repros/math-baseline-read-mode-png.png` (related baseline issue) |
| Math environments have wrong padding in edit mode | Open | — |
| Max content width not applied to read mode | Open | — |
| Images should shrink when content size is small | Open | — |
| Tables should wrap when content size is small | Open | — |
| Table cell content wraps out of the cell | Open | — |
| Click-to-select / select+delete sometimes doesn't work | Open, intermittent | — |
| Scroll glitch from height changes outside viewport | Open, unreproduced ("Lurking" in backlog) | — |
| Cursor stuck at indented position after indented editing | Open, unreproduced; awaiting screen recording | — |
| Undo/Redo and Copy/Paste scrolling "failing again" | Open, unreproduced (post-fix recurrence report) | — |

Do not relabel any of these as fixed without a verified repro flip; no
oversell. When you fix one, update `misc/backlog.md` and this table in the
same branch.

## 7. House rules while debugging

- **Never blanket `pkill -x edmd`.** The user's daily-driver app shares the
  binary name. `pgrep -lx edmd` + `ps -o lstart=,command= -p <pid>`, then
  kill only your own PID (`pkill -f EdmundDbg` if you launched the debug
  bundle).
- **Do not request Computer Access** — Screen Recording and Accessibility are
  already granted.
- **Measure visuals from `screencapture` pixels** (capture by window id, see
  ARCHITECTURE §8), never from headless layout alone.
- **Never mutate storage while `hasMarkedText()`** — including in any
  diagnostic or repro code you add.
- **Never auto-push, PR, or merge.** Branch off `main` per fix; commit small
  and often.
- Logs in `~/.edmund/logs` are app-owned and fair game to read and quote.

## Provenance and maintenance

Built 2026-07-05 from: `docs/ARCHITECTURE.md` (§2, §8, §9),
`docs/delete-drift-investigation.md` (rounds 1–6),
`docs/viewport-glitch-investigation.md`,
`docs/callout-title-wrap-investigation.md`, `docs/live-repro-guide.md`,
`misc/backlog.md`, `docs/ROADMAP.md`, and
`Sources/EdmundCore/TextView/EditorTextView+Diagnostics.swift`. Log strings
(`healing storage edit that bypassed didChangeText`, `repairing content above
origin`, `recovered stranded desync on focus regain`), launch-flag keys,
`fullLayoutMaxLength`, ReproScript commands, the TK1 tripwire, and commit
`5bb2b40` were verified against the source tree on that date.

Maintain it like the codebase docs: when a new bug class is understood, add
its triage row; when a trap costs real time, add its story to §3; when a
backlog bug opens or closes, sync §6 with `misc/backlog.md` in the same
branch. If a row's discriminating check stops matching the code (renamed log
string, moved file), fix the row — a stale runbook is worse than none.
Deeper mechanism detail belongs in the sibling skills and `docs/`
investigation files, not here; this file stays a triage surface.
