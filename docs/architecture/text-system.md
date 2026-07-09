# Text system — TextKit 2 drawing model

Expands `../ARCHITECTURE.md` §2 (invariants) and §5 (TextKit 2 specifics).
Seeded also from the two archived callout investigations
(`../investigations/archives/`) and `../investigations/viewport-glitch-investigation.md`.

## Why TextKit 2 only

TextKit 2 (`NSTextLayoutManager`) lays out only what's on screen (viewport-
based layout), which is what makes large documents tractable — a TextKit 1
document lays out the whole thing up front. The constraint this buys: the
editor must **never** touch `NSTextView.layoutManager` and must **never**
store `NSTextBlock`/`NSTextTable` attributes in the text storage. Either one
silently and permanently switches the view back to TextKit 1 — AppKit falls
back without an error, so a stray `layoutManager` access anywhere in the call
graph (including in a debugger inspection or a well-meaning "just check the
line count" helper) can quietly regress the whole editor to whole-document
layout.

`EditorTextView` (`Sources/EdmundCore/TextView/EditorTextView.swift`) guards
this with a `#if DEBUG` tripwire: it observes
`NSTextView.willSwitchToNSLayoutManagerNotification` and calls
`assertionFailure` if it ever fires, so a debug build crashes loudly at the
moment of the regression instead of silently degrading. Release builds have
no such guard — the regression there is just slow.

## `DecoratedTextLayoutFragment`

A custom `NSTextLayoutFragment` subclass
(`Sources/EdmundCore/TextView/EditorTextView+TextKit2.swift`) draws two kinds
of custom attribute behind/over the laid-out text:

- **`.blockDecoration`** (paragraph-level) — callout boxes, quote bars, table
  borders, thematic-break rules, code-block backgrounds. Fragment frames tile
  vertically, so a multi-line quote/callout run renders as one continuous
  box or bar across its fragments. A `.box` decoration's `bottomPad` grows
  the *last* fragment's own `layoutFragmentFrame` (not just its drawing):
  TextKit 2 excludes trailing `paragraphSpacing` from a fragment's height, so
  padding added only at draw time would be dead space — clicks there would
  miss the text. Growing the frame instead keeps the extra height genuinely
  part of the fragment (clickable, and tiling correctly against the next
  block). A related wrinkle: when a callout is the document's last block and
  the source ends with a trailing newline, TextKit 2 folds that empty final
  line into the *preceding* fragment instead of giving it its own — painting
  the decoration over the full frame height would flood callout color onto
  that empty line. `decorationDrawHeight` detects the absorbed empty line and
  stops the fill at the last real content line plus `bottomPad`.
- **`.fragmentOverlay`** (character-level) — an image *or* a stroked vector
  path drawn at one character's laid-out position: rendered math, list
  bullets/checkboxes, the callout header icon+name image, the custom-title
  callout icon. The mechanism: the anchor character is hidden (see below),
  and `.kern` on that character reserves the overlay's drawing width as
  advance space, so the following text starts clear of where the overlay
  will be painted — the same trick the table renderer uses for column
  alignment. `draw(at:in:)` then paints the image or strokes the path at the
  anchor's computed position once the surrounding text has laid out.

## Hiding mechanics

Delimiters and synthesized-but-in-source markers vanish from view without
changing the string: `hiddenFont` is `NSFont.systemFont(ofSize: 0.01)`,
paired with a clear `foregroundColor`. The character is still there — a
selection can still span it, undo still round-trips it — it simply occupies
no visible space and paints nothing.

This is also why `NSTextAttachment` is off the table entirely: TextKit 2 only
honors an attachment on the placeholder character U+FFFC, and `rawSource`
(the storage==rawSource invariant, `../ARCHITECTURE.md` §2) never contains
that character — Edmund's content is always real Markdown text. Every image
or icon the editor draws is therefore a `.fragmentOverlay`, anchored to a
real (hidden) character, never an attachment.

## Height estimates: the root of most viewport glitches

TextKit 2 only gives a layout fragment a *real* frame once it has actually
been laid out; everything else — including the running total used for
document height and scroll-position math — is an *estimate* that gets
corrected as layout catches up to it. That correction is what makes the
scroller jump, drag-selection autoscroll oscillate, and a scroll-to-target
land in the wrong place; it's a widely documented TextKit 2 limitation (even
TextEdit shows it).

Edmund's mitigations, all converging in
`Sources/EdmundCore/TextView/EditorTextView+LazyStyling.swift`:

- Documents at or under `fullLayoutMaxLength` (100k UTF-16 units) are kept
  **fully laid out** once styling converges, via a coalesced next-run-loop
  settle (`scheduleFullLayoutSettle`) wrapped in `preservingViewportAnchor`
  so the correction can't visibly shift what's on screen. Larger documents
  keep viewport-based (estimate-tolerant) layout — a full layout there would
  be the process-killing path that motivated other mitigations.
- `repairContentAboveOrigin` detects a first-fragment origin that has drifted
  *above* y=0 (edits near the top can leave the scroller stuck at the top
  with unreachable content above it) and re-lays start→viewport to
  renormalize, again inside `preservingViewportAnchor`.
- Undo/redo avoids resetting layout at all where possible (see
  `editor-pipeline.md`'s recompose-path discussion).

Full bug chronicle, including the three separately-reported symptoms this
one root cause explained: `../investigations/viewport-glitch-investigation.md`.

## The image-wedge constraint

Drawing an *image* `.fragmentOverlay` on a **wrapping, multi-line** layout
fragment re-triggers a TextKit 2 layout pass that collapses ("wedges") that
fragment to a single line — clipping whatever wrapped. Drawing a *shape*
(a stroked `CGPath`) on the same fragment does not trigger this. Default
callout headers get away with an image overlay because their synthesized
icon+name text is short and never wraps; the **custom-title** callout header
can wrap (user-supplied title text), so its icon is a stroked `CGPath`
instead — parsed from the vendored Lucide SVG geometry by `SVGPath`
(`Sources/EdmundCore/Model/SVGPath.swift`), scaled and drawn directly in
`CGContext` rather than rasterized to an `NSImage` first. Any *new* overlay
that could end up sharing a line with wrapping text inherits this same
constraint. Full investigation, including the mechanisms tried and rejected
before landing on the stroked-path fix:
`../investigations/archives/callout-title-wrap-investigation.md`.
