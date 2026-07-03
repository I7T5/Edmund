# Viewport glitches (undo/redo, top-edit, drag-select) — investigation notes

Context for anyone touching viewport/scroll behavior again. Three separately
reported symptoms turned out to share one root cause — **TextKit 2 height
estimates** — reached through three different code paths, so this records the
trail end to end.

Fixed on branch `fix/viewport-glitches`, commits:

- `5bb2b40` — fix(undo): select + center the changed text; diff-based snapshot restore
- `340fcbc` — fix(scroll): follow the nearest end of a selection taller than the viewport
- `217da5f` — fix(layout): keep small documents fully laid out (no TextKit 2 estimates)
- `8b4ecfe` — fix(layout): repair TextKit 2 content stranded above the document origin
- `cf10741` — docs: ARCHITECTURE §4/§8 updates

## Symptoms (as reported)

**Bug 1 — undo/redo viewport.** Undo/redo should center the viewport on the
changed text and select it. Instead:

- undo almost always scrolled **too far down** the document;
- redo centered on **wherever the caret sat before the undo**, not on the
  changed text;
- the changed text was never selected.

**Bug 2 — editing at the top.** Editing the first line of a
taller-than-viewport file sometimes pushed the first line **above** the
viewport, with the scroller already at the top — the user **couldn't scroll
up** to reach it. Intermittent.

**Bug 3 — drag-selection jerks.** Evidence:
`~/Desktop/viewport-jerks-in-selection.mov`. Two phases:

1. first half: dragging produced **no visible selection** at all;
2. second half: during a steady downward drag (reporter: "I did not move my
   hand"), the viewport **oscillated** — autoscrolled down, jumped back up,
   repeatedly.

## How it was diagnosed

1. **Git history first.** Prior art on every one of these paths:
   `9aaa11b` (undo/redo viewport hold-or-center), `21cc284`/`2778d6e`
   (cursor-move lurch → `preservingViewportAnchor`), `84123e4` (pin scroll for
   height changes above the viewport), `c49cd5c` (lazy viewport-first
   styling). Each fix was sound but all of them *work around* the same
   underlying instability without naming it.

2. **Code read of the undo path** (`+Undo.swift`) found two concrete defects
   before any experiment:
   - `restoreSnapshot` ran a **full `recompose`** — replacing the entire text
     storage discards every TextKit 2 layout fragment, so *all* geometry
     reverts to estimates. The subsequent `caretIsVisible` /
     `centerViewportOnCaret` math then ran on estimated y-coordinates →
     scroll landed wrong (usually too far down). Explains Bug 1's undo drift.
   - `performUndo` recorded the redo snapshot with
     `currentCursorInRaw()` — the caret **at the moment undo was invoked**
     (user may have clicked/scrolled anywhere since the edit). Redo then
     restored and centered on that stale caret. Explains Bug 1's redo
     behavior exactly.

3. **Frame extraction from the video** (ffmpeg, 4–15 fps + contact sheets)
   confirmed Bug 3 phase 2: monotonic downward autoscroll interrupted by
   ~screen-sized upward jumps. Phase 1 showed a drag with the caret parked at
   the document top and no selection appearing.

4. **Phase-1 explanation came from the diagnostic log**, not the video: the
   verbose trace from that session (`~/.edmund/logs/edmund-2026-07-02.log`,
   20:29) shows `selectionDidChange | sel={0,1526}` — a **whole-document
   selection was already active** when the drag began. Dragging *inside* an
   existing selection is AppKit's drag-*move* gesture, not a new selection.
   So "can't select" was standard (if surprising) AppKit behavior, and it's
   the same gesture family as delete-drift round 4 (`9f99795`), where a
   failed drag-move bypassed `didChangeText`. No new bug.

5. **The upward jumps had exactly one candidate.** During a drag,
   typewriter centering is suppressed (`suppressTypewriterCentering` spans
   `super.mouseDown`), promotion is deferred, and `applyBlockStyle` is
   attribute-only. The only up-scroller left is the **`scrollRangeToVisible`
   override** (`+TypewriterScroll.swift`): when the selection overflowed the
   viewport on *both* edges (a drag selection grown taller than the screen),
   its first branch always revealed the selection **top** — while the drag's
   autoscroll pulled toward the bottom. Two scrollers fighting → oscillation.

6. **Known-issues research** (per the task brief: prioritize documented
   TextKit 2 problems over empirical fiddling) closed the loop on Bugs 1–2.
   Community consensus (Krzyżanowski / STTextView, Apple dev forums):
   - a fragment's frame is only real once laid out; everything else, plus
     `usageBoundsForTextContainer` and total document height, is an
     **estimate** that changes as layout progresses;
   - estimate corrections are what make the scroller jump and scroll-to-range
     land wrong; even TextEdit exhibits it;
   - the reliable recipe for scrolling to a target: ensure layout for the
     target range **first**, then align the viewport to real geometry;
   - the practical mitigation for small documents: keep them **fully laid
     out** so estimates never exist. (This matches the reporter's own
     suggestion: "load small files fully".)

   Sources:
   - https://blog.krzyzanowskim.com/2025/08/14/textkit-2-the-promised-land/
   - https://developer.apple.com/forums/thread/761364
   - https://mjtsai.com/blog/2025/08/15/textkit-2-the-promised-land/

7. **Bug 2 was *not* reproduced live** (see "Verification limits" below). The
   best-supported theory, consistent with the symptom and the research: TK2
   lays out from a viewport anchor using estimated heights for the content
   above; when the estimate is wrong, fragments near the top can be assigned
   **negative y** — content stranded *above the document origin*. The
   scroller (clamped at 0) can never reach it: "first line above the
   viewport, can't scroll up". A targeted detector + repair now exists and
   logs when it fires, so the theory is falsifiable in real use.

## Root cause

**TextKit 2 viewport-based layout only materializes on-screen fragments;
every off-screen frame is an estimate.** Any code that (a) discards layout
unnecessarily, (b) trusts an off-screen y-coordinate, or (c) lets two scroll
policies run concurrently, turns estimate churn into a visible jump:

- Bug 1a: full `recompose` on undo *manufactured* estimates, then measured them.
- Bug 1b: not estimate-related — a plain stale-caret bug in the redo snapshot.
- Bug 2: estimate correction above the viewport strands fragments at y < 0.
- Bug 3: two scroll policies (drag autoscroll vs reveal-selection-top)
  fighting over a selection whose height exceeded the viewport.

## The fixes

**Diff-based undo/redo restore** (`5bb2b40`, `+Undo.swift`):

- `textDiff(old:new:)` — single contiguous changed span (common prefix/suffix
  over UTF-16, surrogate-pair-safe boundaries).
- `restoreSnapshot` applies it with the range-bounded `recomposeReplacing`
  instead of full `recompose`: layout outside the changed span **stays
  real**, so the viewport decision runs on real geometry and small-doc
  documents remain fully laid out through an undo.
- The **changed text is selected** (pure deletion → caret at the deletion
  point). The changed range — not the snapshot's stored caret — drives the
  viewport: hold if any part is on-screen (`rangeIsVisible`), else center it.
  Redo therefore centers on the changed text by construction; the stale-caret
  path is gone. Snapshot caret remains only as a fallback for a no-op diff.
- Typewriter mode: always center the changed text.
- Dirty-set mapping (changed block window + old active block + list-indent
  global) mirrors the edit path's scheme in `+EditFlow`.

**Settle passes in `centerViewportOnCaret`** (`340fcbc`,
`+TypewriterScroll.swift`): after the first scroll the viewport's layout is
real — re-measure the caret line and correct the residual error (≤3 bounded
passes, converges in one). Handles the far-jump case where estimates above
the target can't all be eliminated first.

**Nearest-end reveal** (`340fcbc`, `scrollRangeToVisible` override): when the
range overflows both viewport edges, follow the end **nearest** the current
viewport — that's the end being extended during a drag. The drag's autoscroll
and the reveal now agree on direction; oscillation gone.

**Small documents stay fully laid out** (`217da5f`, `+LazyStyling.swift`):
`scheduleFullLayoutSettle()` — coalesced, next-run-loop
(`RunLoop.main.perform` so tests can drain it), runs after the idle drain
completes and after any dirty flush with nothing deferred. For documents
≤ `fullLayoutMaxLength` (100k UTF-16) it runs `ensureLayout(documentRange)`
inside `preservingViewportAnchor`, so the correction never shifts what the
user is looking at. `ensureLayout` is incremental — per-keystroke settles
only re-lay the blocks that flush invalidated. Large documents keep
viewport-based layout: full layout there is the process-killing path that
motivated the `scrollRangeToVisible` override in the first place.

Why deferred: running the full layout *inside* a caller's own
`preservingViewportAnchor` body poisons that caller's before/after
measurement (the tab-indent stability test caught exactly this — a 366pt
compensation).

**Stranded-content repair** (`8b4ecfe`, `repairContentAboveOrigin`): the
settle also checks the document's **first fragment**; if its `minY < -0.5`,
re-lay start→viewport-end (bounded at 60k chars) inside
`preservingViewportAnchor`. Content above the origin renormalizes to y ≥ 0
and becomes scrollable again; the visible content holds still. Breadcrumb:
`repairing content above origin` in `~/.edmund/logs`.

## Verification

- 805 tests green (14 new):
  - `TextDiffTests` — insertion/deletion/replacement/whole-string/repeated
    chars/surrogate boundaries;
  - `UndoRedoSelectionTests` — redo selects restored text; redo ignores the
    stale caret; undo of a deletion selects the restored span; storage ==
    rawSource invariant + full-recompose oracle across a round-trip;
  - `UndoRedoViewportTests` — off-screen undo centers the change (±30pt),
    redo centers the change after the caret moved away, visible undo holds
    the viewport (<2pt), using the ScrollStabilityTests scroll-view harness.
- Existing stability suites (`ScrollStabilityTests`, typewriter centering,
  lazy rendering, height stability) unchanged and green — they gate the
  regressions this class of change tends to cause.
- Live app launched with the fixes; rendering, caret placement and scrolling
  sane in screenshots.

### Verification limits (honest gaps)

This session's host process could not synthesize keyboard input
(`osascript is not allowed to send keystrokes.`, CGEvent keyboard events
dropped) and synthetic drags never armed AppKit's selection even with
`clickState=1` + 400ms hold. Consequently:

- **Bug 2 was never reproduced live**; the negative-origin diagnosis is
  theory + targeted repair, not a confirmed kill. If it recurs, grep
  `~/.edmund/logs` for `repairing content above origin`: present → diagnosis
  confirmed (and repair maybe raced/undersized); absent → different cause,
  look at estimate corrections that *don't* strand fragments (scroller-only
  jumps) or at `textContainerOrigin`.
- The drag-oscillation fix is verified by reasoning + the reveal logic's
  geometry, not by a live drag.

## Future work / notes for next time

- If Bug 2 survives: consider running `repairContentAboveOrigin` from the
  scroll-promotion observer too (currently settle-only), and instrument
  `usageBoundsForTextContainer` origin.
- `fullLayoutMaxLength` (100k) is a guess with margin; if large-doc users see
  the old glitches at 100k–200k, measure `ensureLayout` cost before raising.
- The undo path still centers the *start* of a multi-screen change; if that
  ever feels wrong, follow the selection-affinity end instead.
- Drag-move of a selection (Bug 3 phase 1) is AppKit-standard but surprised
  the reporter; a UX option (disable drag-move, or require a hold) would be a
  product decision, not a bug fix.
