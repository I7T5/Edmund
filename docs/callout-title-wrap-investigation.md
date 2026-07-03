# Callout title wrapping — investigation notes

Context for anyone revisiting how custom callout titles are rendered. This
captures a long investigation so it doesn't have to be repeated.

## Goal

A callout's header is `> [!type] Optional custom title`. We wanted a **custom**
title to (1) render as **real, literal text** (bold + tinted), (2) **wrap**
inside the box when the window is narrow, and (3) show the type **icon** to its
left.

Default callouts (no custom title) show a synthesized type name ("Note", "Tip")
that isn't in the source, so it must stay an image/overlay.

## The hard constraint

The text storage must always equal `rawSource` (the whole edit pipeline depends
on it). So we can't inject characters, and — per the TextKit 2 notes in
`EditorTextView+TextKit2.swift` — we can't use `NSTextAttachment` for the icon
(TextKit 2 only honors attachments on U+FFFC, which `rawSource` never contains).
The icon therefore has to be drawn as an **image** at the hidden marker's
position, like `.fragmentOverlay` does for math / bullets / the default header.

## The blocker (root cause)

**Drawing any image on a multi-line layout fragment wedges that fragment's
layout to a single line**, clipping the wrapped title. A TextKit 2 reentrancy
quirk: putting an image on screen for that line re-triggers a layout pass that
collapses the wrapping text to one line.

Isolated exhaustively — the title clips when, and only when, the icon image
reaches the screen, by **every** mechanism tried:

| Approach | Result |
| --- | --- |
| Icon as `.fragmentOverlay`, drawn by the layout fragment | CLIP |
| Icon kept out of `overlays` (separate field), drawn in fragment | CLIP |
| Icon drawn frame-relative (no `textLineFragments` read) | CLIP |
| Icon drawn before vs after `super.draw` | CLIP either way |
| Raw `CGContext.draw(cgImage)` instead of `NSImage.draw` | CLIP |
| Icon drawn in the editor's own `draw(_:)` after `super.draw` | CLIP |
| Pre-rasterized to a bitmap, then drawn | CLIP |
| Separate transparent overlay subview drawing the image | CLIP |
| Same overlay, layer-backed (`wantsLayer`) | CLIP |
| CALayer sublayers with `contents = cgImage` | CLIP |

Controls confirming it's specifically *image drawing on a multi-line line*:
no icon at all → WRAP; icon present but the image-draw skipped → WRAP; overlay
computes positions but fills a plain rect instead of the image → WRAP. (Reading
layout is fine; drawing a *shape* is fine; drawing an *image* is not.) The
existing overlays — math, bullets, default callout header — never hit this
because they only ever sit on **single-line** fragments.

So literal-text title + wrapping + an on-line icon image are mutually exclusive
in this TextKit 2 setup.

## Deployment target / newer TextKit 2

Considered bumping `platforms` from `.macOS(.v14)` to v15+ in case a newer
TextKit 2 fixes the reentrancy. Not pursued: no evidence Apple fixed this
specific, obscure interaction, and it would drop macOS 14 (Sonoma) support —
including the dev machine this was found on — so it wouldn't help without an OS
upgrade. If revisiting: reproduce on the newest macOS first (a long custom-title
callout in a narrow window — does it still clip on initial display?).

## What shipped originally

**Drop the icon for custom-title callouts.** A custom title is real, literal,
bold + tinted text that wraps inside the box (wrapped lines hang under the
title); it had **no** type icon. Default callouts keep their icon+name image
(short, single-line, never wraps).

## Resolution (2026-07): draw the icon as a shape, not an image

The control matrix above was the key: *shape* drawing on the multi-line
fragment never triggered the wedge — only *image* drawing did. Lucide icons
are pure stroke geometry, so the icon doesn't have to be an image at all.

Custom-title callouts now get their icon back as a **stroked `CGPath`
overlay**: `SVGPath` converts the vendored Lucide geometry (paths incl. arcs,
circles, rects) to a CGPath, `FragmentOverlay` gained a path form, and
`DecoratedTextLayoutFragment` strokes it directly in CG (round caps/joins,
width 2 scaled from the 24×24 viewBox) instead of blitting an NSImage. The
anchor's `.kern` reserves the icon advance plus a gap; wrapped title lines
hang under the title. Verified live: icon renders, a long title still wraps,
and re-wraps on window resize, with no clipping.

The wedge itself remains unexplained (no matching known TextKit 2 issue was
found) and still constrains any *future* overlay that could share a line with
wrapping text: such overlays must use the path form, never the image form.
See `styleCalloutContent` / `calloutIconPathOverlay` in
`EditorTextView+CalloutRendering.swift`.

## The image alternative (preserved, not shipped)

Rendering the whole header (icon + wrapped title) as a single width-aware image
on a single-line fragment *does* sidestep the wedge, and the image itself
renders correctly. But it has two unsolved TextKit 2 problems: the header
fragment lays out ~2× the `minimumLineHeight` (title sits too low, big empty
band above), and a width-timing race can show a one-line image until a deferred
re-render. That WIP is preserved on branch **`fix/callout-title-image`** for a
possible future revisit.
