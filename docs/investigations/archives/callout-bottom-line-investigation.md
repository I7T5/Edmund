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
3. **The off-screen deferred-restyle branch itself, forced deliberately and
   confirmed to fire** — still clean. Added a `scroll <y>` command to
   `ReproScript` (clamped via `NSClipView.constrainBoundsRect`, so it behaves
   like a real scroll rather than overshooting into blank overscroll).
   Launched with `-EditorTypewriterMode NO` so caret moves don't recenter the
   viewport; a 124-block document (60 filler paragraphs + a trailing
   callout) kept the viewport pinned at y=0 while the callout (~2700pt below,
   confirmed via the clamped scroll target) was activated then deactivated —
   at deactivation the callout was verifiably outside `syncStylingBlockRange`
   (viewport showed only the first ~30 paragraphs), so `blocks[old].isStyled
   = false` / the deferred path is what ran, not the sync path. Scrolled to
   the clamped bottom afterward for the *first-ever paint* of that region.
   Box rendered correctly, no stray line, no color bleed below the box.

All four architectures that plausibly match "live incremental restyle" (per
the prior investigation's framing) have now been tried and are clean:
sync-path activate/deactivate while visible, sync-path deactivate via a real
delete-edit at the exact last-block boundary, and the deferred/off-screen
path through to its first on-screen paint.

## What to try next

- **Typewriter-mode-ON recentering race** (default is ON; this session
  disabled it to isolate the defer path — untested with it on). With
  typewriter mode enabled, deactivating the trailing callout triggers
  `scrollCursorToCenter()` in the same async block right after
  `recomposeDirty` — if the centering scroll animates while TextKit2 is mid
  layout-pass for the just-resized (shrunk/grown) last fragment, a
  transient stale frame during the animation itself (not the settled state,
  which is what every screenshot in this session caught) could be the
  "extra line" — screen recordings catch exactly this kind of one-frame
  glitch that a `screencapture` poll will almost always miss. Try scripted
  recording (`gif_creator`-style continuous capture, or `screencapture -v`)
  through the deactivation moment with typewriter mode on.
- **Read mode** (`viewMode == .reading`) — not tested this session at all.
- Get the actual screen recording. `~/Desktop/callout-bottom-bug.mov` does
  not exist on disk as of this session (checked 2026-07-06) despite being
  referenced in the bug report — ask for it directly, or for the exact
  keystroke sequence that triggers it.

## RESOLVED (2026-07-06, second session) — root cause found and fixed

The user provided the real screen recording
(`misc/bug-repros/callout-extra-line-rendered-at-bottom.mov`, from
2026-06-20 11:26). Watching it changed the picture completely: the trailing
block is **not** a plain paragraph and the doc **does end in a newline**, so
the last block is the *phantom empty final line* the `BlockParser` creates
for a trailing `\n`. My earlier repros all failed because they used a
trailing *text* block ("END") or no trailing newline — never a trailing
empty line after a callout.

**Reproduced deterministically** by reconstructing the doc
(`callout_wrap.md`: three callouts, the last one `> [!tip] Short title\n>
Body text here.` followed by a trailing `\n`) and placing the caret at
end-of-document. Reproduces with typewriter mode **ON and OFF** — so
typewriter mode is *not* involved; the caret position in the video was
incidental.

**Root cause (proved by dumping fragment geometry, not reasoning):** TextKit
2 does **not** give the document's final empty line (from the trailing `\n`)
its own layout fragment — it folds that line into the *preceding* layout
fragment as a trailing **zero-length line fragment**. When the preceding
fragment is a callout's last-line `DecoratedTextLayoutFragment`, its
`layoutFragmentFrame.height` grows by one line (measured: 46.2pt → 74.2pt for
the same callout with vs without the trailing newline; the delta equals one
empty line's height). `draw` fills the box across the full frame height, so
the callout color floods that absorbed empty line — the "extra colored line".
Only happens when the callout is the **last** block: mid-document, the `\n`
after a callout starts the *next* block's fragment instead of being absorbed.

**Why the static/storage checks (both sessions) missed it:** the phantom
line carries no `.blockDecoration` in storage (verified: block deco = none,
the separator `\n` reset to base) — the bug is purely in fragment *drawing
geometry*, invisible to any storage-attribute inspection.

**Fix** (`EditorTextView+TextKit2.swift`): a new `decorationDrawHeight` on
`DecoratedTextLayoutFragment` detects an absorbed trailing empty line (last
line fragment with `characterRange.length == 0` and more than one line
fragment) and returns the frame height minus that empty line's contribution,
so filled decorations (`.box`, `.leftBar`) stop at the last real content line
plus the box's bottom padding. Center-line decorations (rule, table) still
use the full frame. Verified live (the tip box shrank from 222px to 170px,
matching the sibling Note box exactly) and headless
(`CalloutLastBlockRenderingTests`: box fill is identical with and without the
trailing newline, and strictly less than the absorbed frame height).

**Answer to "would the delete-drift fixes have fixed this?"** — No. Delete
drift is a caret/selection *position* desync in the live input layer; this is
a static fragment-*drawing* geometry issue that reproduces on a fresh load
with no delete, edit, or caret interaction at all. Different class entirely.

`ReproScript` gained two reusable DEBUG commands across the two sessions:
`scroll <y>` (viewport control independent of the caret) and `caretend`
(place the caret on the phantom final line, which needles can't target).

## Status

**Fixed.** Branch `fix/callout-last-block-extra-line`. Backlog entry can be
closed once merged.
