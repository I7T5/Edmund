# Editor affordances: invisibles, indent guides, line numbers, focus mode

The editor-only display features. None of them are content: they are edit
affordances, so Read mode and Export never show them (the deliberate exception
to the "one parser, two back-ends" rule — [`../ARCHITECTURE.md`](../ARCHITECTURE.md) §5).
All four are **draw-only**: they write no characters, and — except for the list
guides' cached offsets — no attributes either, so they can't perturb recompose
or break `storage == rawSource` (§2).

`ARCHITECTURE.md` §6 owns the one-line statement of each; this doc owns the
mechanism.

## The rule they all share

**A draw-only setting needs more than `invalidateLayout` to appear.** The
layout manager caches its fragments and hands the cached ones back, so a
paragraph vended as a plain `NSTextLayoutFragment` stays plain and the new
overdraw never shows (measured: a live toggle drew nothing until the next
edit). `refreshOverdraw()` therefore also pokes the storage with an
attributes-only `edited(.editedAttributes, …)` — no text change, no restyle, no
undo entry — which makes the content storage re-offer its elements to the
layout delegate. Invisibles, list indent guides and focus mode all depend on it.

The corollary is what makes these features cheap: toggling one needs only a
re-vend, never a whole-document restyle.

---

## Invisible characters

`TextView/EditorTextView+Invisibles.swift` — faint marks (· → ¬ ␣ ▯) overdrawn
on laid-out whitespace, riding `DecoratedTextLayoutFragment.draw`. Pure display
overlay: inserts no characters (storage == rawSource), TextKit 2 path only. The
delegate vends the decorated fragment for every visible paragraph while on
(viewport-bounded); plain fast path when off (default). Config pushed via
`EditorTextView.invisibles` from `AppSettings.invisiblesConfig`; Settings ▸ Edit.
**Editor-only by design** (like CotEditor) — an edit affordance, not content.

---

## List indent guides

Faint vertical hairlines on list items: one per *ancestor* level spanning the
item, plus the item's **own** column drawn only beside its wrapped continuation
lines (the first line holds the marker).

`depth` comes from `ListDepthMap` — a stack of the indent columns of the lines
above the item, not the item's own indent divided by anything — so a guide's
column depends only on its own list.

Columns are computed by `listGuideOffsets(depth:slotWidth:)`
(`Rendering/EditorTextView+ListRendering.swift`) as the center of each level's
marker slot, and written to `.listGuides` by `styleListItemSpan` **whether or
not the setting is on** — the fragment gates the drawing, so toggling needs only
a re-vend (`refreshOverdraw()`), never a whole-document restyle (there is no
such call).

Offsets are *container*-relative, not `point.x`-relative: the fragment frame
hugs the laid-out text, so `point.x` moves with each item's
`firstLineHeadIndent` (an ordered marker right-aligns into its slot). They are
measured from the container's **text** origin, so the draw adds
`lineFragmentPadding` (the default 5pt — the head indents the columns derive
from are relative to it, and omitting it shifts every guide left by exactly
that).

Drawn under the text in `DecoratedTextLayoutFragment.draw`, filled at one device
pixel like the table gridlines. List paragraphs carry no paragraph spacing, so
per-fragment fills tile into one continuous line down a nested run. Pushed via
`EditorTextView.showListIndentGuides`; Settings ▸ Edit.

---

## Line numbers

`TextView/EditorTextView+LineNumbers.swift` — source line numbers (Settings ▸
Edit ▸ Lines, off by default), pushed via `EditorTextView.showLineNumbers`.
Editor-only, like invisibles — and never printed, since the ruler isn't part of
the text view.

### Two placements over one walk

`enumerateVisibleLineNumbers` / `lineNumberStyle`, and **the placement is not a
setting** — `lineNumbersFitBesideContent`
(`textContainerOrigin.x >= lineNumbersRequiredInset`) picks it, so a margin too
narrow to hold the numbers raises the gutter instead of dropping them. It moves
with the content-width cap, the window width and the document's digit count (no
cap ⇒ a 24 pt base inset, which a 3-digit document already overruns).

The switch can't oscillate: the gutter only ever *shrinks* the margin, so a
document that didn't fit still doesn't, and one that fits without the gutter
fits all the more once it's gone.

### The re-evaluation must be scheduled, not inline

Re-evaluated from `updateContentInset()` — which runs even when the inset held
steady, since the digit count grows on its own — but **only scheduled** there
(`scheduleLineNumberPlacementUpdate`, one coalesced `RunLoop.main.perform`):
`updateContentInset` runs inside `setFrameSize`, and adding or removing a ruler
re-tiles the scroll view, so applying it inline mutates the scroll view from
inside its own layout — that **SIGSEGV'd the whole test process on macOS 14**
(CI caught what six clean local runs on macOS 15 did not). Same constraint as
`ruleThickness`, one layer up.

The margin itself is recomputed from the cap
(`horizontalInset(viewWidth:maxContentWidth:)`), *not* read off
`textContainerOrigin`, which is only correct after `updateContentInset` has run
once — reading the live inset made a freshly built editor see a zero margin,
raise a gutter and immediately drop it.

### Beside the content (the default)

Drawn in the reading column's own margin on `drawBackground(in:)` — the pass
Find already uses — right-aligned a `lineNumberPadding` short of the text.

Reserves **nothing**: the content-width cap owns the margin, so the reading
column always stretches to the full cap and the column never moves when the
numbers come on. The deliberate consequence: when what's left of the margin
can't hold `lineNumbersRequiredInset` (a wide cap, a narrow window), the numbers
step aside rather than print over the text — all of them, never just the ones
that fit, so they can't go ragged with `9` drawn and `100` missing.

Reserving that space instead was tried and reverted: it stopped the column
reaching the cap, and the cap winning is the point. Window-edge is the placement
for "always visible".

### By the window edge (automatic, when the margin can't hold them)

A `LineNumberRulerView` on the scroll view — AppKit owns the scroll sync and
clipping, but it reserves width, so the centered column re-centers when it is
switched on.

Installed by `updateLineNumberRuler()`, which `viewDidMoveToSuperview` replays;
it assigns `lineNumberRuler` **before** telling the scroll view, because showing
or hiding a ruler resizes the document view synchronously and re-enters through
`setFrameSize` — assigning afterwards lets that re-entrant call see nil and
build a second ruler. `Document` configures the editor *before* putting it in a
scroll view, so the setter alone would miss at launch.

`clipsToBounds = true` is **required** on the ruler: against the macOS 14 SDK it
defaults to false, and the background fill then paints over the whole scroll
view (the document goes blank).

### Draw rules

**Walk the viewport the text view already laid out**
(`textViewportLayoutController.viewportRange`) — forcing layout from a draw
re-enters the layout controller and blanks the text view, and enumerating from
the document start would lay out the whole file. Each number comes from its own
fragment's offset through the cached `lineStarts` table, so nothing can drift
when scrolled.

A line whose first line fragment is shorter than half a body line is *counted
but not drawn*, which is how a table's `hiddenFont` separator row (0.01 pt)
avoids stacking its number on its neighbor's — so the visible sequence
legitimately skips in Edit mode and is gapless in Source mode.

Ink is `lineNumberColor`, one tier below `syntaxDimColor` (quaternary /
`darkRuleGray`), except every line the selection touches (`selectedLineSpans`,
kept as ranges so selecting a huge document doesn't build a per-line set each
redraw), which takes `foregroundColor` so it reads as a position rather than
chrome — `selectionDidChange` calls `invalidateLineNumbers()` **before** its own
guards, since the highlight has to follow selection changes that bail out of
restyling, and it dirties only the numbers' strip.

### The face, and why its figures matter

**Avenir Next Condensed** (`lineNumberFont`, CotEditor's choice for the same
job), sized to the theme's monospace face and falling back to
`monospacedDigitSystemFont`. It is *not* monospaced — its **figures are
tabular**, which is the only property the drawing needs: labels are
right-aligned from one measured digit advance rather than measuring each number
(`LineNumberFaceTests` pins this, since a proportional-figure face would break
the alignment silently).

Vertical placement centers the digit's **cap band** on the text's cap band
(tallest font on the line, read off the line fragment's own attributes — the
storage's first character can be a list item's 0.01 pt hidden font and would
report no cap). Centering the drawn *box* instead rides ~2.5 pt high, because
`draw(at:)` lays out a box far taller than the figures in it; baselining instead
sits ~0.8 pt low. Measured on screen: cap-centering lands within 0.1 device px.

### Line ↔ offset lookup

`line(forOffset:)` / `offset(forLine:)` live here too, binary-searching
`lineStarts` (dropped by `rawSource.didSet`) instead of scanning the document;
the status bar and Read-mode scroll sync ride the same speedup.

---

## Focus mode

`TextView/EditorTextView+FocusMode.swift` — dims everything but the lines the
selection touches (Settings ▸ Edit ▸ Editor, and View ▸ Focus Mode; off by
default), pushed via `EditorTextView.focusMode`. Editor-only.

The fade is **one transparency layer around `DecoratedTextLayoutFragment.draw`**
at `focusDimOpacity` (0.35), so a fragment's text *and* everything drawn with it
— code/callout boxes, quote bars, table borders, list guides, math and bullet
overlays — fade as one composite.

That is the point: those live in `BlockDecoration` / `FragmentOverlay` values
and cached images, so fading them through color attributes would mean
recomputing decorations and regenerating overlays on every caret move; fading a
pixel toward an opaque background is the same result as lerping its color toward
it anyway (measured: ink 230 → 107.7 against a predicted 107.2).

It **cannot** be a scrim the text view paints over its content — NSTextView
composites its fragments *after* `draw(_:)` returns, so a fill there lands under
the glyphs and under every box (measured with a full-view test fill: the code
block drew clean over it).

Which fragments dim is decided at draw time from
`textLayoutManager.textSelections` (the invisibles trick — no restyle, no
re-vend, and no work on a caret move beyond the redraw AppKit already does for
the old and new selection), and the mode itself is read live off the vending
editor (`owner`) rather than captured.

One text element is one source line, so element-range containment *is* line
granularity, and it agrees with `selectedLineSpans` behind the line-number
highlight — including the rule that a selection ending exactly at a line start
doesn't claim that line.

While the mode is on every paragraph must vend the custom fragment (a plain one
has no draw to hook); that plain ↔ decorated swap is the only part needing a
re-vend, which is what `refreshOverdraw()` forces.
