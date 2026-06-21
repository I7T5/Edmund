# Callout title wrapping — investigation notes

Context for anyone revisiting how custom callout titles are rendered. This
captures a long investigation so it doesn't have to be repeated.

## Goal

A callout's header is `> [!type] Optional custom title`. We want a **custom**
title to:

1. render as **real, literal text** (bold + tinted) — not a baked image;
2. **wrap** inside the box when the window is too narrow for one line;
3. show the type **icon** to its left.

Default callouts (no custom title) show a synthesized type name ("Note", "Tip")
that isn't in the source, so it must stay an image/overlay — out of scope here.

## The hard constraint

The text storage must always equal `rawSource` (the whole edit pipeline depends
on it). So we can't inject characters, and — per the TextKit 2 notes in
`EditorTextView+TextKit2.swift` — we can't use `NSTextAttachment` for the icon
(TextKit 2 only honors attachments on U+FFFC, which `rawSource` never contains).
The icon therefore has to be drawn as an **image** at the hidden marker's
position, the way `.fragmentOverlay` does for math / bullets / the default
callout header.

## What works

- The **title as real wrapping text** works on its own: hide the `[!type]`
  marker, style the title source bold + tinted, give the header paragraph a
  hanging indent. It wraps correctly (verified 4/4 launches) **as long as no
  image is drawn on that line**.

## The blocker (root cause)

**Drawing any image on a multi-line layout fragment wedges that fragment's
layout to a single line**, clipping the wrapped title. This is a TextKit 2
reentrancy quirk: putting an image on the screen for that line re-triggers a
layout pass that collapses the wrapping text to one line.

It was isolated exhaustively. The title clips when, and only when, the icon
image reaches the screen — by **every** mechanism tried:

| Approach | Result |
| --- | --- |
| Icon as `.fragmentOverlay`, drawn by the layout fragment | CLIP |
| Same, but icon kept out of `overlays` (separate field), drawn in fragment | CLIP |
| Icon drawn frame-relative (no `textLineFragments` read) | CLIP |
| Icon drawn before `super.draw` vs after | CLIP either way |
| Raw `CGContext.draw(cgImage)` instead of `NSImage.draw` | CLIP |
| Icon drawn in the editor's own `draw(_:)` after `super.draw` | CLIP |
| Pre-rasterized to a bitmap, then drawn | CLIP |
| Separate transparent **overlay subview**, drawing the image | CLIP |
| Same overlay, **layer-backed** (`wantsLayer`) | CLIP |
| Overlay using **CALayer sublayers** with `contents = cgImage` | CLIP |

Controls that confirm it's specifically *image drawing on a multi-line line*:

- No icon attribute at all → **WRAP** (4/4).
- Icon present, but the image-draw call skipped → **WRAP**.
- Overlay computes positions (reads `textLineFragments`) but draws a **plain
  filled rect** instead of the image → **WRAP**. (So reading layout is fine;
  drawing a *shape* is fine; drawing an *image* is not.)
- The existing `.fragmentOverlay` icons (math, bullets, default callout header)
  never hit this because they only ever sit on **single-line** fragments.

So: literal-text title + wrapping + on-line icon image are mutually exclusive
in this TextKit 2 setup.

## Deployment target / newer TextKit 2

Considered bumping `platforms` from `.macOS(.v14)` to v15+ in case a newer
TextKit 2 fixes the reentrancy. Not pursued:

- No evidence Apple fixed this specific, obscure interaction.
- It would drop macOS 14 (Sonoma) support — including the dev machine this was
  found on (14.8.3) — so it wouldn't even help here without an OS upgrade.

If revisiting: reproduce on the newest macOS first (a long custom-title callout
in a narrow window — does it clip on initial display?). Only then consider a
target bump.

## Decision

Render the **custom title (icon + wrapped text) as a single width-aware image**
overlay on a single-line fragment — the original image approach, made to wrap.
Single-line fragments with image overlays are fine (that's how default callouts
and math already work), so this sidesteps the multi-line wedge. Trade-off: the
title is a baked image (not selectable literal text) and must be re-rendered
when the content width changes.

The alternative — keep literal wrapping text but **drop the icon** on
custom-title callouts — also works and is simpler; it's the fallback if the
image approach proves too costly (e.g. resize re-rendering churn).
