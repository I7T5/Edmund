# Edit-mode "delete drift" — investigation notes

Context for anyone who sees the bug again. It was intermittent, state-dependent,
and looked nothing like its actual cause, so this records the trail end to end.

Fixed in commits `386604b` (fix + test) and `ef3d87e` (ARCHITECTURE gotcha) on
branch `fix/delete-caret-drift-marked-text`.

## Symptom

In Edit mode the editor would sometimes enter a **bad mode where pressing Delete
(backspace) moved the caret to a different line instead of deleting a
character**. Key properties (all from the reporter):

- **Caret/selection desync, not content corruption** — the underlying text
  stayed correct; the delete was effectively dropped while the caret jumped.
- **Persistent once it started** — *every* delete drifted, not just one. Not
  tied to any particular preceding keystroke.
- **Never right after launch** — only after the window had been used a while.
- **Sometimes cleared by switching to another app and back.**
- **Not list-specific** — reproduced in a plain-paragraph `undo_test.md`.

Evidence: `~/Desktop/delete-jump-2.mov` and `~/Desktop/delete-jump.mp4` (the
latter with a keystroke overlay). A diagnostic log
(`~/Desktop/edmund-2026-06-25.log`) showed only routine I/O — no clue on its own.

## How it was diagnosed

1. **Frame extraction.** Pulling frames from the recordings showed the caret
   teleporting between lines on single Delete presses while the document text
   was stable. That ruled out "wrong text deleted" and pointed at a
   selection/model desync.
2. **Reporter clarifications were decisive** and overturned two earlier wrong
   theories (a viewport-scroll jump, then an Enter-then-Delete interaction):
   - it's caret-only (text fine),
   - every delete drifts once it starts,
   - it's state-dependent (never at launch),
   - **focus-switch clears it**.
3. **The focus-switch clue cracked it.** There is no
   `becomeFirstResponder`/`resignFirstResponder`/window-key handling anywhere in
   the editor (verified in `EditorTextView.swift`), so the *only* state an
   app-focus switch resets that also gates the editor's behavior is AppKit's
   **input-context marked text** (`hasMarkedText()`).

## Root cause

The editor's hard invariant is **text storage always equals `rawSource`**
(ARCHITECTURE §2). It's maintained in `didChangeText` →
`syncRawSourceFromDisplay()`. But that sync — and every other styling entry
point — is gated on `!hasMarkedText()`:

- `EditorTextView+EditFlow.swift` — `didChangeText` (bails **before** syncing)
- `EditorTextView+SelectionTracking.swift` — `selectionDidChange`
- `EditorTextView+LazyStyling.swift` — the idle drain

This guard is correct *during* a live IME / accent / emoji composition: the
storage transiently holds the provisional marked text, so `storage == rawSource`
is briefly false and we must not restyle the marked range (it aborts the
composition).

The bug is when a composition gets **stranded** (`hasMarkedText()` stuck true
with no live composition). Then `didChangeText` keeps bailing forever: the
storage mutates on every keystroke but `rawSource`/`blocks` freeze. From that
point on, every edit does offset / active-block math against a **frozen, stale
block model**, so the caret drifts. Nothing re-syncs until marked text clears —
and the only thing that reliably clears it is the text view resigning first
responder (switching apps), which commits/discards the composition. That is
exactly why **switching apps and back fixed it**, and why it never happened at
launch (you need to accumulate a stranded composition first).

### What stranded the composition

The prime suspect is the **async active-block restyle** scheduled from
`selectionDidChange` (`EditorTextView+SelectionTracking.swift`). The deferred
`DispatchQueue.main.async` block re-checked `isUpdating` but **not**
`hasMarkedText()`. Because it's scheduled on a caret move and runs a turn later,
a composition can begin in between; the block then runs `recomposeDirty`
(`beginEditing`/`setAttributes`/`endEditing` + `invalidateLayout`) over storage
that holds a live composition, which can strand the marked text in the input
context. Timing/usage dependent → "after a while," never at launch.

## The fix (two defenses)

1. **Prevention** (`EditorTextView+SelectionTracking.swift`): add
   `guard !self.hasMarkedText() else { return }` to the async restyle block, so
   it matches the guard every other storage-touching styling path already has.
   The active-block restyle still happens — `didChangeText`'s
   `recomposeDirty` covers the active block when the composition commits.

2. **Recovery** (`EditorTextView.swift`,
   `recoverFromStrandedCompositionIfNeeded` + a `becomeFirstResponder`
   override): regaining first-responder status is a reliable "composition is
   over" signal (the view can't become first responder while it already holds an
   active composition). If the invariant is broken at that moment, commit any
   stranded marked text (`unmarkText()`) and resync the model from storage. This
   makes the focus-switch recovery the user already relied on **deterministic**
   instead of occasional, and is a catch-all for *any* future stranding path.

The new gotcha bullet in ARCHITECTURE §8 states the general rule: **never mutate
storage while `hasMarkedText()`**, including async paths scheduled before
composition began.

## Testing — and its limit

`Tests/EdmundTests/MarkedTextDesyncTests.swift`:

- `markedTextBreaksInvariantTransiently` — documents that `setMarkedText` makes
  `storage != rawSource` (the normal, transient state).
- `regainingFocusRecoversStrandedComposition` — strands a composition, simulates
  leave-and-return focus, and asserts the invariant is restored and a delete
  then removes exactly one character. **This fails without the recovery hook**,
  so it's the real regression guard.

**Limit:** the *actual* stranding can't be reproduced headlessly. A unit-test
`NSTextView` has no live `NSTextInputContext`, so `recomposeDirty` running during
marked text does **not** corrupt/strand it the way the real input context does
(verified by probing: `activeBlockIndex` was unchanged with or without the
prevention guard). So:

- Fix 1 (prevention) is justified by **consistency** with the codebase's own
  established pattern, not by a failing test.
- Fix 2 (recovery) is the test-backed safety net.

A DEBUG assertion in `didChangeText`'s marked-text guard was considered and
**rejected**: during normal composition the invariant is legitimately broken, so
it would false-fire on every IME keystroke.

## If it ever recurs

1. Check the invariant first: is `textStorage.string == rawSource`? If not, the
   model has desynced.
2. Check `hasMarkedText()`. If it's stuck true outside an active composition,
   a styling path mutated storage mid-composition again — audit every
   storage-touching path for the `!hasMarkedText()` guard (especially any new
   async/deferred styling, like new scroll/idle/promotion paths).
3. The `becomeFirstResponder` recovery should still unstick it on focus regain;
   if it doesn't, confirm the override is being called and that
   `recoverFromStrandedCompositionIfNeeded` isn't guarded out.
4. To get live signal, read `~/.edmund/logs` for the
   `recovered stranded desync on focus regain: …` line — it's emitted (release
   too, `Log.info`) whenever focus-regain recovers a desync and snapshots
   `hasMarked` / `isUpdating` / `isUndoRedoing`, which tells you the cause.

## Follow-up: recurred without deliberate IME (round 2)

It came back — reportedly **without** CJK IME / accents / emoji — and clicking
away and back still fixed it. That second clue narrows the cause by elimination:

- The recovery hook only acts when `storage != rawSource`, and it *did* fix it,
  so the edit **reached storage** → `shouldChangeText` returned `true` →
  `isUpdating` was **false** at edit time (it's the only flag that makes
  `shouldChangeText` return `false`). So `isUpdating` stuck-true is **excluded**
  (it would make edits do nothing, not drift).
- That leaves `didChangeText` bailing on `isUndoRedoing` or `hasMarkedText`. A
  stuck `isUndoRedoing` is **excluded** too: the recovery doesn't reset it, so it
  would re-break on the very next keystroke rather than be durably fixed by a
  focus switch.
- By elimination it is **still stranded marked text** — `unmarkText()` in the
  recovery is what durably clears it. The composition just came from a source the
  user doesn't think of as "IME": most likely **automatic text completion /
  inline predictions**, which inject provisional marked text as you type and were
  still enabled (every *other* auto-substitution was already off).

**Fix (round 2):** disable the remaining marked-text sources in `commonInit`
(`EditorTextView.swift`) — `isAutomaticTextCompletionEnabled = false` and, on
macOS 14+, `inlinePredictionType = .no` — matching the four auto-substitutions
already disabled there. Kept a permanent `Log.info` in
`recoverFromStrandedCompositionIfNeeded` so any *future* recurrence records which
guard stranded the sync (the first thing to grep for if it happens again).

## Round 3: recurred post-fix — and why we built diagnostics instead

A third reproduction (`misc/bug-repros/delete-caret-drift-3.*`) on a build that
**already had the round-1 and round-2 fixes**, editing a heading immediately
followed by a list. Three facts narrowed it:

- The log had **no `recovered stranded desync` line** — so either the invariant
  held or recovery never ran. The desync-via-marked-text signature didn't appear.
- A **headless probe** of the exact gesture (backspace at the start of a list
  item under a heading) showed the **model is correct**: the caret moves back by
  one each press, `storage == rawSource` holds, and `blocks` reconstruct
  `rawSource` throughout. The video's caret jump did **not** reproduce headlessly.
- **Timing clue:** the reporter confirms it only appears **after a few minutes of
  editing in the same window** — never on a freshly opened one. So the trigger is
  *accumulated live-session state* (TextKit 2 layout / input-context / NSTextView
  internal state), not the document content or any single keystroke. A fresh
  window is clean; something builds up. This is why it resists headless and
  short-session reproduction — and why the verbose trace must be left running
  across a long editing session to catch the transition.

Conclusion: the core edit/parse model is sound; the drift is a **live
NSTextView / TextKit 2 / input-context** phenomenon that cannot be reproduced or
inspected headlessly. Chasing it blind is the wrong move — so this round added
**in-app diagnostics** to capture the live trail at reproduction time:

- **Verbose editor tracing** (`Log.trace` / `Log.shouldTrace`, category `.edit`,
  gated by Settings ▸ Advanced ▸ "Verbose editor tracing", off by default). The
  edit pipeline (`shouldChangeText`, `didChangeText` incl. the bail reason,
  `syncRawSourceFromDisplay`, `selectionDidChange`) emits one line per event with
  a live-state prefix: caret range, active block, marked-text range, the
  `isUpdating`/`isUndoRedoing` flags, and storage-vs-rawSource lengths
  (`EditorTextView+Diagnostics.swift`). A reproduction now yields a readable
  keystroke-level trail in `~/.edmund/logs`.
- **Always-on invariant tripwire** (`verifyEditorInvariants`, called after each
  sync): an O(1) `storage.length != rawSource.length` check logs an `error`
  whenever the hard invariant breaks — no verbose toggle needed. The full
  structural check (string equality + blocks reconstruct rawSource + in-bounds
  ranges) runs under verbose and asserts in DEBUG.

**Next time it happens:** ask the reporter to enable "Verbose editor tracing,"
reproduce, and send `~/.edmund/logs`. The trace shows exactly when the caret
diverges from the edit and what the marked-text / flag / length state was at that
instant — which should finally localize the live-layer cause (still-sneaking
marked text vs. a TextKit 2 selection-after-edit quirk).
