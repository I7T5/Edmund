# Callout-as-last-block extra line — investigation notes

## Goal

Bug report (`~/Desktop/callout-bottom-bug.mov`, referenced twice: June and
2026-07-06): when a callout is the last element in a file, the editor renders
an extra line, in the callout's tinted color, not prefixed by `>`. Only seen
when the callout is the file's last block. Tracked in `misc/backlog.md` and
`edmund-debugging-playbook`'s open-bug inventory.

Prior investigation (2026-06-ish) already ruled out the static composition
pipeline: `styleCalloutContent` geometry (`EditorTextView+CalloutRendering.swift`)
is correct in every constructible state via offscreen bitmap rendering —
active→leftBar, inactive→box, trailing empty `> ` continuation line, callout
as last block, tall view. The bug was concluded to live in the **live
incremental restyle path**, not reproducible via `loadContent`/`recompose`.

## What this session ruled out (2026-07-06)

**Hypothesis: the trailing-newline phantom paragraph inherits the box
decoration.** `BlockParser.LineBuffer` does append a synthetic empty final
block when `rawSource` ends with `\n` (see the "Trailing newline: one final
empty segment" comment). But `EditorTextView+TextKit2.swift`'s
`textLayoutFragment(for:)` vends a **plain** `NSTextLayoutFragment` for any
`NSTextParagraph` with `attributedString.length == 0` — decorations never
draw for it regardless of what attribute might be present. Dead end,
confirmed by code reading, not tested live.

**Hypothesis: the separator-reset in `recomposeDirty`/`drainStylingSlice`
misses the callout-as-last-block case.** Read closely: `recomposeDirty`
(`EditorTextView+Composition.swift:118-126`) and `drainStylingSlice`
(`EditorTextView+LazyStyling.swift:73-76`) both reset the block's trailing
separator character to base attributes whenever that block is in the
restyled set — the guard `sep < nsString.length` simply skips the reset when
there's no separator (block is at the true end of the string), which is
correct, not a bug. `applyBlockStyle()` (`EditorTextView+Rendering.swift:583`,
the per-keystroke path) never does this reset, but it also never writes past
the block's own range, so it can't leave anything stale on the separator
either. No divergence found between the static and live paths in this logic.

**Live repro attempts — all clean, no artifact observed:**

1. Small doc (paragraph + trailing callout, whole doc visible, no
   scrolling), `ReproScript` caret moves in and out of the callout
   repeatedly. Screenshots taken before/during/after each transition
   (`~/.claude/jobs/e0af50f0/tmp/s*.png` this session). Box renders cleanly
   both directions.
2. Same, but the callout became the last block via a **real delete-edit
   sequence** (`backspace` through a trailing paragraph so the callout's
   separator and everything after it is actually removed via
   `shouldChangeText`/`didChangeText`, not a fresh load) — then deactivated.
   Still clean.
3. Did **not** manage to force the off-screen deferred-restyle branch
   (`EditorTextView+SelectionTracking.swift`'s `else { self.blocks[old].isStyled
   = false }`), which prior memory flagged as the most likely suspect
   mechanism: typewriter mode (`typewriterModeEnabled = true` by default)
   re-centers the viewport on every caret move via `scrollCursorToCenter()`,
   so a `ReproScript caret` jump never leaves the old active block
   off-screen — the visibility check that picks sync-vs-defer always sees it
   as visible. `ReproScript` has no scroll command, and CGEvent-driven
   trackpad/wheel scrolling wasn't attempted this session (out of budget).

## What to try next

- Disable typewriter mode via launch default (`-EditorTypewriterMode NO`,
  see `AppDelegate.typewriterModeKey` in `Sources/edmd/App/main.swift`) so a
  `ReproScript` caret jump does **not** recentre the viewport, then drive the
  editor into the deferred/off-screen branch deliberately: caret into the
  callout, caret to a block far above (off-screen deactivation, `isStyled =
  false`), let `drainStylingSlice`/`promoteVisibleUnstyledBlocks` process it,
  then find a way to bring it back on screen and screenshot the first paint.
  `ReproScript` has no scroll primitive — either add one (see its "~10 lines
  each" extension note) or drive scrolling with the CGEvent driver
  (`edmund-live-repro-and-diagnostics` §4).
- Get the actual screen recording. `~/Desktop/callout-bottom-bug.mov` does
  not exist on disk as of this session (checked 2026-07-06) despite being
  referenced in the bug report — ask for it directly, or for the exact
  keystroke sequence that triggers it.
- Consider whether the bug needs `viewMode == .reading` (Read mode) rather
  than edit mode — not tested this session.

## Status

Still open. No fix attempted — the standing rule from the prior
investigation holds: don't ship a speculative tweak to the (provably
correct) static box geometry.
