---
name: edmund-failure-archaeology
description: >
  The chronicle of every major bug investigation, dead end, rejected fix, and
  revert in the Edmund Markdown editor. Load BEFORE re-investigating any
  caret/selection symptom (drift, jump, desync), any viewport/scroll glitch
  (lurch, oscillation, wrong landing, can't-scroll-up), any rendering wedge
  (clipped wrap, one-line collapse, blank space), or any release/update
  failure (signing, appcast, Sparkle "improperly signed"). Load before
  proposing a fix that might already have been tried and reverted, when a bug
  report "looks familiar", when a test passes but the live app still misbehaves,
  or when wondering why the code does something weird (a guard, a re-assert, a
  deliberately-missing icon). Every entry: symptom, root cause, evidence
  (commit hashes, docs), status, and what NOT to retry.
---

# Edmund failure archaeology

Chronicle of settled battles. Purpose: nobody re-fights one. Each entry gives
symptom → root cause → evidence → status. Hashes are on `main` unless noted.
Dates are commit dates. Status vocabulary: **settled** (root-caused, fix
verified), **mitigated-unconfirmed** (fix shipped, never seen killing a live
occurrence), **open** (in `misc/backlog.md`), **reverted-pending-redo**.

## When NOT to use this skill

- Designing a change / asking "why is it built this way" → `edmund-architecture-contract`.
- Actively debugging a NEW symptom (method, not history) → `edmund-debugging-playbook`.
- Driving the live app to reproduce something → `edmund-live-repro-and-diagnostics` (and `docs/live-repro-guide.md`).
- TextKit 2 / AppKit API semantics → `textkit2-appkit-reference`.
- Cutting or fixing a release → `edmund-release-and-operate` (this file only records how 0.1.0 broke).
- Build environment, stale-link traps in depth → `edmund-build-and-env`.
- Deciding whether a change is safe to make at all → `edmund-change-control`.
- Test strategy / what the suite can and cannot catch → `edmund-validation-and-qa`.
- The ongoing caret-integrity program (forward-looking) → `edmund-caret-integrity-campaign`.
- Debug flags (`-debug.reproScript`, verbose tracing toggles) → `edmund-config-and-flags`.

---

## 1. The delete-drift saga (rounds 1–6) — issue #156

The hardest bug in the project's history: pressing Delete moved the caret to a
different line instead of deleting. Six rounds, 2026-06-25 → 2026-07-04.
Full trail: `docs/delete-drift-investigation.md` (read it before touching
`+EditFlow` / `+SelectionTracking` / the heal). One symptom, FOUR distinct
root causes stacked on top of each other — each fix was real, and each round's
recurrence was a different mechanism underneath.

**STATUS: settled through round 6** (shipped in 0.1.3, 2026-07-04). The class
— live-only caret/selection desync — remains the project's hardest problem;
new rounds are possible. Backlog still lists "Delete caret drift" under
On-going bugs as a class to watch, not a known unfixed defect.

### Round 1 — stranded IME marked text (2026-06-26, `386604b` + docs `ef3d87e`)

- **Symptom:** once it started, EVERY delete drifted; never at launch; cleared
  by switching apps and back. Text stayed correct — caret-only desync.
- **Root cause:** every styling path bails on `hasMarkedText()` (correct during
  live IME composition). A *stranded* composition (`hasMarkedText()` stuck true,
  no live composition) made `didChangeText` bail forever → `rawSource`/`blocks`
  froze while storage kept mutating → all caret math ran against a stale model.
  Strander: the async active-block restyle in `+SelectionTracking` re-checked
  `isUpdating` but not `hasMarkedText()`, so it could run `recomposeDirty` over
  a live composition scheduled one turn earlier.
- **Fix:** (a) add the missing `!hasMarkedText()` guard to the async restyle;
  (b) `becomeFirstResponder` recovery hook — `unmarkText()` + resync when the
  invariant is broken on focus regain (made the user's accidental focus-switch
  cure deterministic).
- **Why it came back:** the guard closed one strander; other marked-text
  sources existed (round 2), and other desync mechanisms entirely (rounds 4–6).

### Round 2 — marked text without "IME" (2026-06-27, `a1f3219`)

- **Symptom:** recurred with no CJK/accent/emoji input. Focus-switch still cured it.
- **Root cause (by elimination, documented in the doc):** still stranded marked
  text — from **automatic text completion / inline predictions**, which inject
  provisional marked text on plain typing.
- **Fix:** `isAutomaticTextCompletionEnabled = false`, `inlinePredictionType = .no`
  in `commonInit`, plus a permanent `Log.info` breadcrumb in the recovery hook.
- **Why it came back:** the next recurrence wasn't marked text at all.

### Round 3 — no fix; built diagnostics instead (2026-06-28, `5dae387`, `3aaeb04`, PR #139)

- **Symptom:** recurred on a build with rounds 1–2. NO `recovered stranded desync`
  log line; a headless probe of the exact gesture showed the model was CORRECT.
  Only appeared after minutes of editing in one window.
- **Conclusion:** the model/parse layer is sound; the drift is a live
  NSTextView / TextKit 2 / input-context phenomenon invisible headless. Chasing
  it blind was declared the wrong move.
- **Shipped:** verbose editor tracing (Settings ▸ Advanced, `Log.trace`,
  category `.edit`, per-event live-state prefix) + an always-on O(1) invariant
  tripwire (`verifyEditorInvariants`, logs `error` on length mismatch). This
  instrumentation is what cracked rounds 4–6. Lesson: when a live-only bug
  resists reproduction, ship diagnostics, not guesses.

### Round 4 — drag-move deletes with NO `didChangeText` (2026-07-02, `9f99795`, PR #163)

- **Symptom (from the round-3 trace):** drifting deletes showed
  `shouldChangeText` → *nothing* → `selectionDidChange` mid-recompose with a
  stale caret. Origin event: a drag-select, then `shouldChangeText OK repl=""`,
  then LEN-MISMATCH forever — `didChangeText` never fired.
- **Root cause:** AppKit's drag-**move** gesture, when the drop lands past the
  end of the document (or fumbles), performs the source deletion via
  `shouldChangeText` → `replaceCharacters` and **never calls `didChangeText`**.
  `rawSource` silently froze — and **autosave wrote the stale bytes**: this was
  a data-corruption bug, not just a caret bug.
- **Fix:** `shouldChangeText` schedules a next-run-loop bypass check
  (`RunLoop.main.perform`): a `pendingEdit` still unconsumed one pass later ==
  didChangeText was bypassed → run the same sync it would have, log
  `healing storage edit that bypassed didChangeText` (release too). Exempt
  while `isUpdating`/`isUndoRedoing`/`hasMarkedText()` (IME legitimately defers).
- **Why it came back:** the heal restored the *model* but rounds 5–6 found the
  heal itself could move the caret.

### Round 5 — the heal leaped the caret (stale selection) (2026-07-03, `422498f`, docs `c4a602b`, merged `222dd86`, PR #166)

- **Symptom:** heal fired, invariant restored, bytes correct — but the caret
  leaped to the END of the document at the heal moment.
- **Root cause:** when the bypassed deletion removes the *selected* text, AppKit
  also skips its usual selection fix, so at heal time the selection still spans
  deleted text (e.g. {951,37} in a 973-char doc). The heal's restyle makes
  AppKit re-resolve the invalid selection → clamps to document end.
- **Fix:** before syncing, the heal **collapses an out-of-bounds selection** to
  the edit point. (Headless NSTextView clamps this itself — the test documents
  intent; only live layout reproduces the leap.)
- **Why it came back:** this out-of-bounds clamp was a special case of the real
  mechanism, found in round 6.

### Round 6 — TextKit 2's queued selection fixup: the drift mechanism itself (2026-07-04, `1b1420a`, branch `fix/wrapped-paragraph-caret-drift`, merged `218d922`, PR #169)

- **Symptom:** typing mid wrapped paragraph, one backspace leaped the caret +43
  ("two viewport-lines down"); drift no longer continuous — one delete drifts,
  the next ones don't. Model fine; a heal had fired 80 seconds EARLIER.
- **Root cause (named via a `traceSelectionOrigin` stack capture):** a normal
  edit runs TextKit 2's `_fixSelectionAfterChangeInCharacterRange` synchronously
  inside its own transaction. A didChangeText-bypassing mutation skips that too,
  so the fixup **stays queued and fires at the NEXT `endEditing`** — the heal's
  attribute-only restyle — where it maps the stale selection against post-edit
  coordinates and drops the caret blocks away. Fires exactly once (state is
  then synchronized), explaining "drifts once, then fine". Round 5's clamp was
  the sub-case where the stale selection ran past the shrunk document end.
- **Fix:** the heal derives the correct caret from the pendingEdit hull and
  sets it **both before AND after** `syncRawSourceFromDisplay()`. The
  before-only version still leaped — **the queued fixer moves even a freshly
  set, fully valid caret** during the sync's `endEditing`. The post-sync
  re-assert is the load-bearing half; the pre-set keeps `cursorRaw`/active-block
  styling correct.
- **The breakthrough repro** (first deterministic one in six rounds):
  `ReproScript.swift` (DEBUG-only, `-debug.reproScript <path>`) replays
  keystrokes in-process through `window.sendEvent(_:)` — no TCC, works on an
  invisible Space. `bypassdelete <needle>` simulates the drag-move deletion
  exactly; one bypass beforehand → the next delete always drifts. Typing alone
  never drifts. See `edmund-live-repro-and-diagnostics`.

### Do not retry (proven dead across the saga)

- **Headless/unit tests for this class.** The test harness runs TextKit 2's
  selection fixups synchronously, so the deferred-fixup state never forms. The
  round-6 unit test **passes with and without the fix** — it is a contract
  spec, not a regression guard. Only the ReproScript live repro discriminates.
  Do not "add a test to catch it" and call the class covered.
- **CGEvent injection as the default live driver.** Round 6's session dropped
  the events (per-session TCC), and the app's windows launch on an inactive
  Space. Use ReproScript first.
- **DEBUG assertion in `didChangeText`'s marked-text guard** — rejected in
  round 1: the invariant is legitimately broken during composition; it
  false-fires on every IME keystroke.
- **"No explicit selection repair needed"** (round 4's claim) — wrong twice.
  Any new heal-like path must handle selection explicitly, before and after.
- **`swift build` trusted after "Build complete!"** — round 6 hit a stale-link
  relink failure TWICE; two "failed" fix iterations were phantoms running old
  code. Verify with `strings` on a LONG literal (≤15-byte literals inline on
  arm64 and never show), cure with `swift package clean`, never hand-delete
  `edmd.build/`. Details: `edmund-build-and-env`.

---

## 2. Undo/redo viewport drift — the costliest failure

**STATUS: settled** (2026-07-02, `5bb2b40`, part of PR #164) — with one caveat:
`misc/backlog.md` "Lurking (Unreproduceable)" carries a later note "Undo/Redo
and Copy/Paste scrolling is failing again". No repro exists. Treat the
*mechanism* below as settled and any new report as a NEW investigation that
starts from this entry.

- **Symptom:** undo scrolled too far down; redo centered on wherever the caret
  sat before the undo; changed text never selected.
- **Root cause (two defects, found by code read before any experiment):**
  1. `restoreSnapshot` ran a **full `recompose`** — replacing the entire
     storage discards every TextKit 2 layout fragment, resetting ALL geometry
     to height estimates; the subsequent centering math measured estimates.
  2. `performUndo` recorded the redo snapshot with the caret *at undo
     invocation time* (stale), and redo centered on it.
- **Fix:** `textDiff(old:new:)` single contiguous changed span → range-bounded
  `recomposeReplacing` (layout outside the span stays real); the **changed
  range** — never a stored caret — is selected and drives the viewport (hold if
  visible, else center).
- **Load-bearing contract: never full-recompose on undo/redo.** Anyone
  "simplifying" `restoreSnapshot` back to `recompose` reintroduces the bug.
  Guarded by `TextDiffTests`, `UndoRedoSelectionTests`, `UndoRedoViewportTests`.
- **Prior art that treated symptoms without naming the estimate problem:**
  `9aaa11b` (undo hold-or-center), `2778d6e`/`21cc284` (cursor-move lurch),
  `84123e4` (pin scroll above viewport), `c49cd5c` (lazy viewport-first
  styling). All sound, all workarounds; `5bb2b40` removed the manufactured
  estimates at the source.

---

## 3. Viewport glitches — TextKit 2 height estimates (PR #164, 2026-07-02)

Full trail: `docs/viewport-glitch-investigation.md`. Three reported symptoms,
one root cause: **every off-screen TextKit 2 frame is an estimate**; code that
discards layout, trusts off-screen y, or runs two scroll policies at once turns
estimate churn into visible jumps. Community-documented (Krzyżanowski /
STTextView, Apple forums) — even TextEdit exhibits it.

- **Bug 1 (undo/redo):** entry 2 above. **STATUS: settled** (same caveat).
- **Bug 2 (editing at top pushes line 1 above the viewport, can't scroll up).**
  Theory: TK2 assigns fragments **negative y** when estimates above the
  viewport correct downward; scroller clamps at 0. Mitigations `217da5f`
  (documents ≤100k UTF-16 kept **fully laid out** via a deferred
  `scheduleFullLayoutSettle` — estimates never exist) and `8b4ecfe`
  (`repairContentAboveOrigin`: first fragment `minY < -0.5` → re-lay
  start→viewport-end inside `preservingViewportAnchor`; breadcrumb
  `repairing content above origin`).
  **STATUS: mitigated-unconfirmed.** The doc is explicit: Bug 2 was **never
  reproduced live**; the repair had not been confirmed against a live
  occurrence as of this writing (2026-07-05). If it recurs: grep
  `~/.edmund/logs` for the breadcrumb — present means diagnosis confirmed but
  repair raced/undersized; absent means different cause (scroller-only
  estimate jumps, or `textContainerOrigin`).
- **Bug 3 (viewport oscillates during a steady drag-select).** Two scrollers
  fighting: drag autoscroll pulling down vs the `scrollRangeToVisible`
  override always revealing the selection **top** once the selection outgrew
  the viewport. Fix `340fcbc`: reveal the **nearest** end. **STATUS: settled
  by geometry/reasoning** — a live drag was never synthesized (that session
  couldn't arm AppKit selection). Phase 1 of the same report ("can't select")
  was NOT a bug: a whole-doc selection was active, so the drag was AppKit's
  drag-move gesture — same family as delete-drift round 4.
- **Do not retry:** raising `fullLayoutMaxLength` without measuring
  `ensureLayout` cost (full layout on large docs is the process-killing path
  that motivated the lazy pipeline); running a full layout *inside* a caller's
  `preservingViewportAnchor` (poisons its before/after measurement — the
  tab-indent stability test caught a 366pt compensation; that's why the settle
  is deferred).
- Backlog keeps "Inaccurate viewport estimates and things related" under
  On-going bugs, plus a lurking "glitch when scrolling" — the estimate class
  is managed, not extinct. Roadmap v1.0.0 carries "TextKit 2 viewport
  stabilization".

---

## 4. Callout-title wrap / the image wedge (settled 2026-07-03, `aa45563` + `ae61644`, PR #165)

Full trail: `docs/callout-title-wrap-investigation.md` — including a 10-row
matrix of dead ends.

- **Symptom/goal:** custom callout titles (`> [!type] Title`) should render as
  real wrapping text with the type icon; any attempt to draw the icon clipped
  the wrapped title to one line.
- **Root cause:** **drawing any IMAGE on a multi-line layout fragment wedges
  that fragment to a single line** — an unexplained TextKit 2 reentrancy quirk.
  Isolated exhaustively: fragment overlay, frame-relative draw, before/after
  `super.draw`, raw `CGContext.draw`, editor-level `draw(_:)`, pre-rasterized
  bitmap, transparent subview, layer-backed subview, CALayer `contents` — ALL
  clip. Controls: no icon → wraps; positions computed but plain rect filled
  instead of the image → wraps. Reading layout is fine; drawing a **shape** is
  fine; drawing an **image** is not.
- **Fix:** the icon is a **stroked `CGPath`** — `SVGPath` parses the vendored
  Lucide geometry, `FragmentOverlay` gained a path form,
  `DecoratedTextLayoutFragment` strokes it in CG. Verified live: icon renders,
  long titles wrap and re-wrap on resize.
- **Standing constraint:** any future overlay that can share a line with
  wrapping text MUST use the path form, never the image form. Existing image
  overlays (math, bullets, default callout header) survive only because they
  sit on single-line fragments.
- **Do not retry:** any image-drawing mechanism from the matrix; bumping the
  deployment target to macOS 15 on the hope newer TextKit 2 fixed it (no
  evidence, drops Sonoma incl. the dev machine). The whole-header-as-image
  alternative is preserved on branch `fix/callout-title-image`
  (tip `c7f5170`, unmerged): it sidesteps the wedge but has two unsolved
  problems (~2× line height band above the title; a width-timing race).
- Still open nearby (backlog): callout icon baseline / crispness; the
  callout-at-end-of-file extra colored line (live-path rendering bug).

---

## 5. The 0.1.0 release failures (2026-06-26 → 2026-07-02)

Reference: ARCHITECTURE §13. Five separate failures shipping and updating the
first releases. **STATUS: all settled**, with one time bomb (PAT expiry).

1. **`sign_update -s` exits 1 for new keys** (`59565f5`, 2026-06-27, PR #135).
   Sparkle deprecated `-s <key>`; for keys generated after that change it
   prints a warning and exits 1. Killed the first 0.1.0 release. Fix: key on
   **stdin** — `echo "$SPARKLE_ED_PRIVATE_KEY" | sign_update --ed-key-file - <dmg>`.
   Do not retry `-s`.
2. **Bundle not sealed → EVERY update failed "improperly signed"**
   (`5e54b40`, 2026-06-29, issue #158). Sparkle re-validates the Apple code
   signature at install (`SUUpdateValidator` → `SecStaticCodeCheckValidity`);
   the build signed only the main binary, never sealed the bundle, so a valid
   EdDSA signature didn't save it. Fix: `codesign --deep` the whole `.app` —
   and because SwiftMath's resource bundle must sit at the `.app` root
   (`Bundle.module` hardcodes `Bundle.main.bundleURL`) and codesign won't seal
   a bundle with root items, **seal first, copy the SwiftMath bundle in
   AFTER sealing**. The lone unsealed root item trips strict
   `codesign --verify` but not Sparkle's non-strict check (verified against
   that exact API). Do not "fix" the ordering or the failing strict verify.
3. **Appcast push to protected `main` rejected, `GH006`** (`e56a4dd`,
   2026-06-28, PR #140). `GITHUB_TOKEN` isn't admin; `enforce_admins: false`
   means an admin PAT bypasses the required check. Fix: fine-grained admin PAT
   in secret **`RELEASE_TOKEN`**, set on the **checkout step** (not the push
   URL — `actions/checkout` persists an `extraheader` credential that
   overrides inline-URL creds). **`RELEASE_TOKEN` expires 2027-06-27**; rotate
   before then or releases fail at the appcast push.
4. **create-dmg quirks** (`098d8c0`, 2026-06-26, documented in §8): it's the
   **npm** create-dmg (sindresorhus), not the Homebrew tool; Node ≥20;
   **exit code 2 for unsigned images is success**; space-in-filename
   normalization.
5. **Release workflow YAML invalid** (`854f85d`, 2026-07-02, merged `232e6c8`,
   PR #162). Literal multi-line bash strings inside a `run: |` block had
   unindented lines — invalid in a YAML block scalar; the whole workflow file
   failed to parse. Fix: build the strings with `printf` `\n` escapes; also
   `$(...)` strips trailing newlines, so the separator newline lives in
   `NEW_ITEM`'s format string, not `DESC_BLOCK`.

---

## 6. Reverts and abandoned directions

- **Selection tint** — `ee173f7` (2026-06-26): reverted an experimental
  selection color back to **accent-derived (accent @ 30% alpha)**.
  **STATUS: settled.** Don't re-hardcode a bespoke selection color.
- **`img.md-image { display:block }` in the export/Read HTML theme** —
  `75d2824` (2026-06-25): reverted; it did NOT fix the image blank-space and
  broke layout. The commit title itself records the verdict: **image
  blank-space is a separate, STILL-OPEN bug** (backlog: "Attached image
  padding… creates a large empty space below",
  `misc/bug-repros/image-blank-after.mov`). Do not retry display:block for it.
- **Checkbox click-to-toggle + table borders** — `9991413` (2026-06-03):
  pulled from a branch for separate passes. **STATUS: partially redone.**
  Table work landed later (edit-mode table alignment shipped, per backlog
  Done); Read-mode click-to-toggle checkbox is still in the v1.x backlog —
  **reverted-pending-redo**. The original attempt lives on stale branch
  `feature/checkbox-toggle` (merged history, `d6227e3`).
- **TextKit 2 migration regressions** — `b3a4b29` (2026-06-12): the TK1→TK2
  migration silently broke inline-math height, HR spacing, and scroll; fixed
  with `RenderingRegressionTests` as the guard. Lesson: TK2 migrations
  regress silently in geometry — extend that suite when touching layout.
- **Stale branches that look abandoned but are MERGED** (don't "rescue" them):
  `feature/incremental-recompose` (tip `1222f79`, in main) and
  `refactor/word-level-rendering` (merged via PR #8, `7eb6a21` — word-level
  delimiter hiding became the shipped approach). The genuinely unmerged WIP
  branches are `fix/callout-title-image` (entry 4) and dozens of old merged
  topic branches never deleted.

---

## 7. Wrapped-paragraph caret drift (PR #169) — same battle as round 6

`fix/wrapped-paragraph-caret-drift` / merge `218d922` IS delete-drift round 6
(entry 1): the branch name comes from the reporting symptom (backspace mid
wrapped paragraph), but the root cause was the queued TextKit 2 selection
fixup armed by an earlier bypassed drag-move edit — the wrapped paragraph was
incidental. **STATUS: settled** with `1b1420a`. If a caret drift is reported
"in a wrapped paragraph", do not assume wrapping is the mechanism; check for a
preceding heal breadcrumb in `~/.edmund/logs` first.

---

## 8. Smaller settled battles (one paragraph each; verified in git)

- **Flaky math fit-width test — took TWO rounds** (`5421297` 2026-06-06 branch
  `fix/flaky-math-test`, then `352bdc9` PR #65). First fix pinned the text
  container width (tracking off) — the flake persisted ~1 in 3 runs. Real
  cause: **shared theme-defaults state pollution** between tests; fixed with
  isolated defaults. Lesson: a flake "fix" that doesn't name the shared state
  isn't done.
- **Emoji rendered as missing-glyph boxes** (`0f5ffba`, 2026-06-06).
  `EditorTextStorage.fixAttributes` is a deliberate no-op (so `.attachment` on
  real characters survives) — which also disabled font substitution. Fix:
  perform substitution manually (Apple Color Emoji per composed-character
  sequence, ZWJ/skin-tone graphemes whole). Don't re-enable the framework
  `fixAttributes`; it strips the marker attachments.
- **Nested list hanging indent** (`8d2088f`, 2026-06-06, PR #64).
  swift-markdown's list-item delimiter excludes leading indentation; the
  visible spaces broke the hang. Fix: hide the leading whitespace in the
  inactive branch; indentation comes entirely from the paragraph style.
- **Ordered-list deep nesting lost styling** (`b255903`, 2026-06-06).
  swift-markdown parses ≥4-space indent as indented code; the rescue regex
  only matched `[-*+]`. Extended to `\d{1,9}[.)]`. Any new list-ish syntax
  must be added to the rescue parser too.
- **Window size persistence — three commits to get right** (`538ff6e` →
  `d967bcf` → `678c5d6`, 2026-06-28, PR #144). Saving content-view size made
  windows grow taller on reopen (titlebar double-counted); final form stores
  the **full window frame** and restores via `setFrame`.
- **Toolbar right-click interception — three failed view-level attempts**
  (`4eb604a`, `6723280`, then `f8472ca`, 2026-06-26). View `.menu`,
  `rightMouseDown`, and a gesture recognizer all lost to the toolbar's
  "Customize Toolbar…" menu. Working fix: `DocumentWindow` overrides
  `NSWindow.sendEvent` — the documented funnel ahead of the toolbar — and
  swallows secondary clicks on the view-mode button. Do not retry view-level
  interception for anything the titlebar/toolbar claims.
- **Invisible CJK input** (`a3df387`): IME-composed text was invisible until
  committed; fixed by keeping marked text visible. Related to (and predating)
  the round-1 marked-text rules.

---

## 9. Still OPEN — do not let this chronicle imply otherwise

Per `misc/backlog.md` (cross-checked 2026-07-05): footnotes don't render
(edit or Read); math doesn't render in Read mode; math padding in edit mode;
**image blank-space below attached images** (see the `75d2824` revert);
callout-at-end-of-file extra colored line; max content width not applied to
Read mode; tables don't wrap/shrink at small content sizes; table-cell content
wraps out of the cell; "sometimes click to select / select+delete doesn't
work" (unreproduced); lurking scroll glitch from off-viewport height changes;
lurking indented-cursor-stuck report; lurking "undo/redo and copy/paste
scrolling failing again" (see entry 2 caveat). Delete-caret-drift and
viewport-estimate classes stay on the watch list even though every known
mechanism is fixed.

---

## Provenance and maintenance

- Written 2026-07-05 by mining: `docs/delete-drift-investigation.md`,
  `docs/viewport-glitch-investigation.md`,
  `docs/callout-title-wrap-investigation.md`, `docs/ARCHITECTURE.md` §13,
  `CHANGELOG.md`, `misc/backlog.md`, `docs/ROADMAP.md`, and `git log --all`
  (every hash above verified with `git show` on that date).
- **Code and git win over prose.** If this file disagrees with a commit or the
  current source, trust the commit, then fix this file.
- **Update triggers:** a new delete-drift round (append to entry 1 — never a
  new doc); any live confirmation or refutation of `repairContentAboveOrigin`
  (flip entry 3 Bug 2 off mitigated-unconfirmed); `RELEASE_TOKEN` rotation
  (entry 5); any revert (entry 6); closing a backlog bug named in entry 9.
- Keep the status vocabulary exact; "mitigated-unconfirmed" is not "fixed".
  No oversell — this file's value is that its claims can be trusted blind.
- Sibling map lives in "When NOT to use" above; keep it in sync as the skill
  library grows.
