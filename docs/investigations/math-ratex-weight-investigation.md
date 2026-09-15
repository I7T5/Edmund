# Math rendering "weight" (RaTeX, edit vs read mode) — investigation notes

Context for anyone who sees this again: the report ("math looks heavier in
edit mode than in read mode") survived two rounds of chasing the wrong layer
— the rendering pipeline (antialiasing, WebKit compositing, CSS pixel
ratios) — because those *do* have a real, separate bug in them (fixed below,
Round 1), which made them a plausible-looking but wrong suspect for this
specific report. The actual cause (Round 2) is a one-line color difference
between the two modes' text color, present for every glyph, not RaTeX- or
math-specific at all.

Not yet fixed — Round 2 ends in a design question for the maintainer, not a
code change. Round 1's fix is on branch `feat/extensions-registry-and-tab`
(uncommitted at time of writing): `Sources/EdmundCore/Export/DocumentHTML.swift`.

## Symptom

- User-reported: "math rendering... every character in display equations
  look slimmer... inline equations [and] edit mode [are] slightly more
  weighted."
- Two distinct claims bundled together:
  1. Read mode: inline math vs display math look different weights.
  2. Edit mode vs read mode: edit mode's math looks heavier, most obvious
     tracing a single glyph (the user's own repro: an isolated "$f$",
     `misc/bug-repros/math-ratex-f-edit-mode.png` vs
     `math-ratex-f-read-mode.png`).
- Both screenshots are the *same* RaTeX-rendered "f", same font size,
  different display context.

## How it was diagnosed

### Round 1 — inline vs display, read mode

1. Confirmed via a direct JSCore dump that RaTeX's DisplayList JSON is
   byte-identical for the same LaTeX regardless of `\displaystyle` wrapping
   — ruled out RaTeX itself.
2. Screencaptured a read-mode "x = a" (inline) next to "x = a" (display) and
   ran connected-component analysis on the "=" sign's two bars. Measured a
   real asymmetry: inline 2px+2px, display 1px+2px.
3. Traced a real bug: `DocumentHTML.pngData()` computed the PNG's pixel
   dimensions via an *independent* rounding (`size.width * scale`, rounded)
   from whatever CSS `height` (and unset `width`) `fillMath()` declared —
   the two roundings could disagree, leaving a non-exact native-pixel-to-
   CSS-pixel ratio that forces WebKit to resample the bitmap on composite.
   Fixed: `pngData()` now returns the PNG's actual pixel size; `fillMath()`
   derives both CSS `width` and `height` from that (exact ratio, guaranteed).
4. Re-measured after the fix: the "=" sign asymmetry (1px+2px vs 2px+2px)
   was **unchanged** — same numbers, before and after, and unmoved by two
   different `image-rendering` CSS hints (`-webkit-optimize-contrast`,
   `pixelated`; the latter is nearest-neighbor and would have made *any*
   real resampling obvious — it didn't).
   - Along the way, one of those CSS attempts had zero effect for a
     boring reason: it was written as a `//` line comment inside the CSS
     string literal in `HTMLTheme.swift`. CSS has no `//` comment syntax;
     the whole rule silently failed to parse. Worth remembering next time a
     CSS change in `HTMLTheme.swift`'s raw string "does nothing" — check
     for `/* */`, not `//`.
5. **Switched from a brightness-threshold pixel count to an antialiasing-
   aware measurement** — integrated ink darkness (`Σ(255 − L)` over each
   row/region, not a binary "is this pixel dark" cutoff). Result: inline and
   display total ink were equal within noise (70.46 vs 70.60, ~0.2% apart).
   The original "1px+2px vs 2px+2px" finding was a **threshold artifact** —
   a real antialiased stroke that happens to split its coverage across pixel
   rows differently at two slightly different sub-pixel offsets reads as
   "asymmetric" under a hard brightness cutoff even when its *total* ink is
   identical. Conclusion: inline/display read-mode math is not measurably
   different in weight; Round 1's real bug (the CSS ratio mismatch) was
   worth fixing but was not the mechanism behind either report.

### Round 2 — edit mode vs read mode

1. Started from the user's own repro crops (`misc/bug-repros/math-ratex-f-
   edit-mode.png`, `math-ratex-f-read-mode.png`) rather than a fresh
   screencapture — different crop sizes (27×43 vs 38×48), so raw totals
   aren't directly comparable.
2. Normalized both to a common glyph height (200px, LANCZOS resize) and
   compared ink density (`ink / area`): 0.2176 vs 0.2142 — 1.6% apart, i.e.
   not a meaningful stroke-geometry difference once scale is controlled for.
   (An un-normalized comparison of the raw crops showed a bigger gap, but it
   tracked almost exactly with the ~13% larger glyph bounding box in the
   edit-mode crop — a scale/crop artifact, not a weight difference.)
3. **Decisive test**: the darkest pixel in each crop.
   - Edit mode: RGB(0, 0, 0) — pure black.
   - Read mode: RGB(35, 35, 35) — never reaches black.
   This can't be antialiasing or resampling noise — it means the *fill
   color itself* differs between the two renders, independent of geometry.
4. Traced to source:
   - `EditorTextView+MathRendering.swift`'s `mathOverlay(latex:display:
     fontSize:)` colors math with `foregroundColor`, which is
     `EditorTextView.foregroundColor { .textColor }`
     (`Sources/EdmundCore/TextView/EditorTextView.swift:174`). Resolved
     directly (`NSAppearance(named: .aqua).performAsCurrentDrawingAppearance
     { NSColor.textColor.usingColorSpace(.deviceRGB) }`): **RGB(0, 0, 0)** in
     light appearance.
   - `DocumentHTML.fillMath()` colors math with
     `NSColor(hex: dark ? "#e6e6e6" : "#1a1a1a")` — **RGB(26, 26, 26)** in
     light mode, not black.
   - That same `#1a1a1a`/`#e6e6e6` pair is `HTMLTheme.swift`'s `--fg`
     variable (`let fg = dark ? "#e6e6e6" : "#1a1a1a"`) — the color for
     **all** read-mode text, not just math.

## Root cause

**Edit mode colors math (and everything else) with the system `.textColor`
(pure black in light appearance); read mode colors math (and everything
else) with a deliberately softer palette — `#1a1a1a` light / `#e6e6e6` dark —
applied uniformly via `--fg`.** This is a whole-document "editing UI vs
reading palette" choice, not a RaTeX defect, not a rendering-pipeline bug,
and not specific to math at all: any glyph, rendered in both modes, would
show the same gap, because both modes' math renderer is handed its
surrounding context's ambient foreground color and (correctly) matches it —
exactly the behavior you'd want for inline content sitting next to prose.
Pure black inherently reads as higher-contrast/heavier than an off-black at
any stroke width, which is what "tracing the $f$s" made obvious: a single
isolated glyph has no surrounding prose to visually calibrate against, so
the color gap alone was enough to read as a weight difference.

This explains the report fully and is a *different* mechanism from Round
1's real bug (the CSS pixel-ratio mismatch) — that one only affected
read-mode inline vs display, and turned out not to produce a measurable
weight difference either, once measured correctly.

## The fix

**No code change.** This is a genuine, deliberate design decision (each
mode's math matches its own ambient text color — the semantically correct
behavior for inline content), not a bug to silently patch. Fixing the
*symptom* means picking one of two product decisions, neither obviously
"more correct":

- Make edit-mode text (not just math) use a softer palette instead of
  `.textColor`, matching read mode's book-like contrast — a change to
  *all* edit-mode text, not just math.
- Make read-mode text pure black — loses the intentional softer reading
  contrast (`#1a1a1a`/`#e6e6e6` reads as a deliberate choice, common in
  reading-focused apps to reduce eye strain vs true black-on-white).

Left for the maintainer to decide; math should keep matching whichever
ambient color its mode settles on either way.

## Verification

- Pixel evidence: darkest-pixel test on the user's own repro crops (§ above)
  — decisive, not resampling-sensitive.
- Source evidence: both color expressions read directly from
  `EditorTextView+MathRendering.swift`, `EditorTextView.swift:174`, and
  `DocumentHTML.swift`/`HTMLTheme.swift`; `.textColor`'s actual RGB value
  confirmed by resolving it under `NSAppearance(named: .aqua)` rather than
  assumed.
- Round 1's fix (`DocumentHTML.swift` exact-pixel-ratio) verified via
  before/after screencapture + connected-component measurement; `swift
  test` green (838 tests) with the fix in place.

### Honest limits

- The user's repro crops are small (dozens of glyph pixels); the normalized-
  density comparison (§ Round 2.2) has real measurement noise from a 6×
  LANCZOS upsample and isn't precise to better than a few percent. The
  qualitative conclusion (color, not geometry) doesn't depend on that
  precision — the darkest-pixel test does the real work — but a
  quantitative "X% of the perceived weight is color vs geometry" split
  isn't established beyond "geometry's share is small, color's share is
  real and provably nonzero."
- Dark-mode read-mode color (`#e6e6e6`) vs edit-mode dark-appearance
  `.textColor` wasn't independently re-verified with a fresh screenshot —
  the light-mode mechanism (confirmed) applies symmetrically by the same
  source-code logic, but this wasn't re-shot to double-check.

## If it ever recurs

Check the two color expressions first — `EditorTextView.foregroundColor`
(`.textColor`) vs `DocumentHTML`'s hardcoded hex / `HTMLTheme`'s `--fg` —
before re-chasing rendering/antialiasing/CSS theories. Resolve `.textColor`
directly under the relevant `NSAppearance` rather than assuming its RGB
value; it is not pure black in every context (only confirmed for light
appearance here).
