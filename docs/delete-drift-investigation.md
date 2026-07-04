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

## Round 4: the round-3 diagnostics caught it — a drag-move deletes without `didChangeText`

The verbose trace (`misc/bug-repros/edmund-2026-06-30_delete-caret-drift-4.log`)
paid off. Reporter's extra clue: drifts start **right after drag-selecting text
and doing something with it**. Fixed on branch
`fix/delete-caret-drift-round-4`.

### What the trace showed

Every drifting delete had one signature, distinct from healthy deletes:

- **Healthy**: `shouldChangeText` → `selectionDidChange` (up=N, transient
  LEN-MISMATCH, caret already adjusted) → `synced` with correct `cursorRaw`.
- **Drifting**: `shouldChangeText` → *nothing* → `selectionDidChange` **up=Y**
  (fires mid-recompose, storage and rawSource both already synced, caret
  already leaped) → `synced` logged with a **stale** `cursorRaw`.

Walking back to the first bad event found the origin (11:06:17–19):

```
selectionDidChange sel={329,17}                 ← drag-select
shouldChangeText OK range={329,17} repl=""      ← 1s gap = drag gesture
selectionDidChange sel={329,0} storLen=329 rawLen=346 ⚠︎LEN-MISMATCH
                                                ← storage shrank; NO synced /
                                                  SKIPPED / DEFERRED line ever
```

`didChangeText` **was never called** for that deletion. Every path through our
override logs *something*, so the call itself was absent — an AppKit path that
runs `shouldChangeText` → `replaceCharacters` and skips the closing
`didChangeText`.

### Live reproduction (deterministic)

Scripted CGEvent automation against the real app found the exact gesture:

1. Drag-select some text.
2. **Drag the selection and drop it past the end of the document** (below the
   last line — a drop that falls through to no valid insertion target, or
   toward another window). The move's insert half syncs fine; the **source
   deletion** then runs `shouldChangeText` → `replaceCharacters` with **no
   `didChangeText`**.
3. `rawSource`/`blocks` silently freeze (LEN-MISMATCH on every following trace
   line). The desync also reaches disk: **autosave writes the stale
   `rawSource`** — this was a data-corruption bug, not just a caret bug.
4. Click into another block and press Delete: the heal-on-next-edit sync runs
   *inside* that keystroke, NSTextView's own selection adjustment arrives late
   and resolves against the mid-restyle layout, and the caret leaps (in the
   repro: 210 → 371, then snapping toward doc end on each delete) — exactly
   the round-1/2/3 symptom.

Consistent with rounds 1–3: focus-switch "fixed" it (any recovery resync), it
needed accumulated state (a prior fumbled drag), and it never reproduced
headlessly (drag sessions are live-app-only).

### The fix

`EditorTextView+EditFlow.swift` — `shouldChangeText` schedules a **bypass
check on the next run-loop pass** (`RunLoop.main.perform`, coalesced by
`bypassedEditCheckScheduled`): `didChangeText` consumes the storage's
`pendingEdit` synchronously within the same event turn, so a `pendingEdit`
still unconsumed one pass later is exactly the "didChangeText was bypassed"
signal. The check then runs the same sync `didChangeText` would have
(`syncRawSourceFromDisplay` + dirty-change count), and logs a permanent
`healing storage edit that bypassed didChangeText` breadcrumb (release too).
Guards: skipped while `isUpdating` / `isUndoRedoing` / `hasMarkedText()` (an
unconsumed `pendingEdit` during IME composition is legitimate — the commit's
`didChangeText` syncs it).

Verified live with the scripted repro: the heal fires ~60ms after the rogue
deletion, and the previously-drifting delete sequence runs with healthy
ordering and a correct caret. `Tests/EdmundTests/BypassedEditSyncTests.swift`
covers the heal and the IME-composition exemption headlessly.

### Why the caret leaped during the *heal* sync (round-4 mechanics)

When the heal ran lazily (inside the next delete's `didChangeText`, as before
the fix), that keystroke's model math used the stale blocks and NSTextView's
own post-edit selection fix was deferred past our recompose — it then resolved
against invalidated layout and landed the caret at the following block
boundary. Healing on the run-loop pass right after the rogue edit (before any
further keystroke) removes both ingredients; no explicit selection repair was
needed.

## Round 5: the heal itself leaped the caret (stale selection)

Recurred 2026-07-03 (~11:25, editing ROADMAP.md) on the round-4 build. The
heal worked — invariant restored, autosave wrote correct bytes — but the
caret leaped to the **end of the document** at the heal moment:

```
11:25:14.834 selectionDidChange sel={951,37}              drag-select
11:25:15.172 shouldChangeText OK range={951, 37} repl=""  drag-move deletion, no didChangeText
11:25:15.207 healing storage edit ... storLen=973 rawLen=1010
11:25:15.208 selectionDidChange sel={973,0} up=Y          caret at doc end
```

Round 4's "no explicit selection repair needed" was wrong for one case: when
the bypassed deletion removes the *selected* text itself, the bypassing path
also skips AppKit's usual pre-`didChangeText` selection fix, so at heal time
the selection still spans text that no longer exists ({951,37} in a 973-char
doc). The heal's restyle invalidates layout, AppKit re-resolves the invalid
selection, and clamps it to the document end.

Fix: before `syncRawSourceFromDisplay`, the heal collapses an out-of-bounds
selection to the edit point (`min(location, length)`, zero length). Covered
by `healRepairsSelectionSpanningDeletedText()` — though note headless
NSTextView clamps the selection itself, so the test documents intent; the
leap only reproduces under live layout.

## Round 6: TextKit 2's queued selection fixup — the drift mechanism itself

Recurred 2026-07-03 ~22:13 (hodge-poster.md) on the round-5 build: the user
typed "While go" mid wrapped paragraph, backspaced the "o" → the caret leaped
+43 to the end of the block (sel 294 → 337); the next backspace deleted the
block separator and leaped to the end of the document (337 → 388). Two new
field observations shaped the investigation:

- the first drift is always "two viewport-lines down";
- the drift is no longer continuous — a delete that drifts is followed by
  deletes that don't (unlike rounds 4/5).

No heal breadcrumb at the drift moment, no LEN-MISMATCH persisting, `synced`
lines present — the *model* was fine. The drifting deletes' signature was a
`selectionDidChange` arriving **mid-recompose** (up=Y) at a wrong position,
with no pre-sync up=N notification. And 80 seconds *earlier* the log showed a
heal (a drag-move bypass at 22:11:57) followed immediately by three backspaces
with a *stuck* caret — the same up=Y signature. That temporal link (bypass →
later delete drifts) became the working hypothesis.

### How it was finally reproduced (the first deterministic repro in 6 rounds)

Everything before round 6 relied on reading traces from the user's live
sessions; every scripted attempt had failed to drift. What failed, and why,
matters as much as what worked:

1. **Windowed unit test, real `deleteBackward`** (`WrappedParagraphCaretTests`
   first version): reconstruct the exact document, caret mid wrapped
   paragraph, type "While go" via `insertText`, then `deleteBackward(nil)`
   with run-loop drains. **Passed** — under the test harness NSTextView
   updates the selection synchronously; the deferred-fixup state never forms.
   Lesson: this bug class is invisible headless, full stop.

2. **CGEvent injection** (the round-4 approach: drive the real app with
   synthetic clicks/keys): this session's TCC context silently dropped the
   events — clicks and keys posted fine but never arrived. Also the app's
   windows launch on an inactive Space (`kCGWindowIsOnscreen == false`), and
   `osascript`/System Events activation was denied assistive access.
   Lesson (already in memory, reconfirmed): CGEvent-based repro depends on
   per-session TCC grants you can't count on.

3. **In-process replay — the breakthrough.** If events can't be injected from
   outside, have the app inject them itself: `ReproScript.swift` (DEBUG-only,
   `-debug.reproScript <path>`) replays a command script against the front
   document by synthesizing `NSEvent` key events and pushing them through
   `window.sendEvent(_:)` — the full, authentic AppKit route (keyDown →
   interpretKeyEvents → insertText:/deleteBackward:), no TCC involved, and it
   works with the window on an invisible Space. Commands: `sleep <ms>`,
   `caret <needle>` (place caret before first occurrence), `type <text>`,
   `backspace <n>`, `logsel`, and the two that cracked the case:
   - `bypassdelete <needle>` — simulates the drag-move source deletion
     exactly as AppKit performs it: select the range, call
     `shouldChangeText`, mutate the storage, **never call `didChangeText`**;
   - `assertcaret <needle>` — PASS/FAIL log line iff the caret sits exactly
     before `<needle>` (position-independent, so soak scripts survive
     upstream edits).

4. **First scripted run reproduced the leap immediately and deterministically**:
   `bypassdelete "Sizemore,"` → heal fires → caret lands at **321** instead
   of 290, every run, window not even visible. Typing and backspacing alone
   (step 1's recipe) never drifts; one bypassed edit beforehand always does.
   The trigger was never the typing — it was the silent drag-move bypass
   minutes earlier.

### Naming the culprit: `traceSelectionOrigin`

New verbose diagnostic (`+Diagnostics`): any `selectionDidChange` arriving
while `isUpdating` (the drift signature) logs a condensed call stack. One run
later the mover had a name:

```
-[NSTextView(NSSharing) setSelectedRanges:affinity:stillSelecting:]
-[NSTextLayoutManager _fixSelectionAfterChangeInCharacterRange:changeInLength:]
-[NSTextContentStorage synchronizeTextLayoutManagers:]
-[NSTextStorage endEditing]
recomposeDirty ← syncRawSourceFromDisplay ← the heal
```

The mechanism: a normal edit runs TextKit 2's selection fixup synchronously
inside its own editing transaction (the same stack appears under
`deleteBackward` → `_NSDoUserReplaceForCharRange` on healthy deletes). A
didChangeText-bypassing mutation skips that too — the fixup **stays queued**
and fires at the *next* `endEditing`, which is the heal's attribute-only
restyle. There it maps the by-then-stale selection against post-edit
coordinates and drops the caret blocks away. This also explains both field
observations: the landing offset (+31 chars here) spans about two wrapped
lines in the user's window, and the fixer fires exactly once — after it the
TextKit state is synchronized and deletes behave until the *next* silent
bypass (hence "drifts once, then fine").

Round 5's fix was a special case of this: when the stale selection happened
to run past the shrunk document end, the late fixer clamped it to the
document end. The out-of-bounds clamp caught that variant and no other.

### The fix — and the iteration that proved its shape

In the heal (`+EditFlow`): derive the correct caret from the pendingEdit hull
(`oldRange.location + max(0, oldRange.length + delta)` — the edit's end
point), then:

1. `setSelectedRange` **before** `syncRawSourceFromDisplay()` — first attempt.
   **Still leaped to 321**: the queued fixer runs during the sync's
   `endEditing` and moves even a freshly set, fully valid caret.
2. Re-assert the same caret **after** the sync as well — the fixer has fired
   by then and its state is clean (verified: all follow-up edits healthy).
   The pre-set is still kept so the sync computes `cursorRaw`/active-block
   styling from the right position.

### Verification

- Deterministic repro flips: logsel 321 → **290** with the fix.
- Soak (per the "accumulate a session" suggestion): one script, one app run,
  four bypass+heal cycles at different document positions with typing,
  backspaces, and block-merge deletes between them — **all five `assertcaret`
  PASS**, final state byte-identical across runs.
- Full suite green (810). The unit test survives as a contract spec but
  cannot catch a regression (see step 1); the scripted live repro is the
  regression harness — script preserved in the test bundle's sibling docs and
  reproducible in one command.

### Build-system trap hit twice this round

`swift build` twice reported `Build complete!` while linking a **stale**
`edmd` binary — the compile step ran (`Compiling edmd ReproScript.swift`
visible in the log) but the relink silently didn't, so the app kept executing
old code and two "failed" fix iterations were phantoms. Detection: check
`strings .build/arm64-apple-macosx/debug/edmd` for a string literal unique to
the new code (beware: literals ≤15 bytes are stored inline on arm64 and never
show up — grep for a *long* one). Cure: `swift package clean`. Never delete
`edmd.build/` by hand — that corrupts the output-file-map and wedges the
target until a clean.
