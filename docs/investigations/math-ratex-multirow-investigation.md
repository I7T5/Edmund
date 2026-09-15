# RaTeX multi-row (`aligned`) layout — investigation notes

Context for anyone who sees this again: two reports that looked unrelated
(edit mode overlapping the following paragraph; read mode collapsing a
multi-line derivation onto one line) turned out to share one upstream root
cause, found by dumping RaTeX's own DisplayList JSON rather than guessing
from screenshots.

> **Superseded — see Round 2 at the end of this file.** The root cause
> recorded below is wrong: it rests on a comparison between two different
> equations rather than one equation across two RaTeX versions. Measured
> head-to-head, 0.1.12 stacks all of these correctly. Kept as written for the
> record; read Round 2 first.

Not fixed — root cause is upstream (`erweixin/RaTeX`'s WASM), not
Edmund's rendering. Tracked in `misc/backlog.md` as a **ship blocker** for
the Advanced Math extension, alongside the separate inline-renders-as-
display-mode gap (dev acknowledged, see
[erweixin/RaTeX#128 (comment)](https://github.com/erweixin/RaTeX/discussions/128#discussioncomment-17579171)).

## Symptom

- Edit mode: a multi-line `\begin{aligned}` display-math block's rendered
  image overlaps the paragraph below it — `misc/bug-repros/math-ratex-
  padding-issue.png` (a 3-row derivation; the garbled placeholder text
  typed below it visibly collides with the image's last two rows).
- Read mode: the same category of multi-row derivation renders as one
  continuous horizontal line instead of stacked rows — `misc/bug-repros/
  math-ratex-multiline-read-mode.png` (compare the same content correctly
  stacked in edit mode, in the first screenshot, elsewhere in the same
  document).
- Both screenshots predate the unrelated read-mode CSS-pixel-ratio fix in
  `docs/math-ratex-weight-investigation.md` Round 1 (`math-ratex-padding-
  issue.png` is 2026-07-08 15:10; `math-ratex-multiline-read-mode.png` is
  2026-07-08 16:53; that fix landed 2026-07-09). That fix only touches
  `DocumentHTML.pngData`'s CSS width/height derivation — it doesn't touch
  edit-mode's line-height reservation or RaTeX's own layout math, so it
  couldn't have caused or fixed either of these regardless of timing.

## How it was diagnosed

1. Read the edit-mode overlay code
   (`Sources/EdmundCore/Rendering/EditorTextView+Rendering.swift`): display
   math reserves vertical space via `displayMathParagraphStyle(padded:
   imageHeight:)` → `ps.minimumLineHeight = imageHeight`, where `imageHeight
   = overlay.bounds.height`. That in turn comes straight from
   `RenderedMath.ascent + .descent`, which for RaTeX
   (`Sources/EdmundCore/Math/RaTeX/DisplayListRenderer.swift:150-152`) is
   `dl.height * fontSize` / `dl.depth * fontSize` — RaTeX's own reported
   ascent/descent, trusted verbatim, no safety margin.
2. Hypothesis: if RaTeX under-reports `height`/`depth` for multi-row
   content, both bugs fall out of the same number — edit mode reserves too
   little space (bug 1), and if the same under-reported vertical span is
   what the row *positions* are computed against, rows could end up
   compressed toward each other too.
3. **Tested directly** rather than continuing to guess: added a one-line
   temporary hook to `WasmMathHost.render()` (env-var gated, `try?
   json.write(toFile: "/tmp/ratex-dump.json", …)`, reverted after use) to
   capture RaTeX's raw DisplayList JSON for two synthetic test documents.
4. **Simple 3-row `aligned`** (`a &= b \\ c &= d \\ e &= f`): `height=2.5`,
   `depth=2.0` (em), three cleanly separated item Y values — `[0.84, 2.34,
   3.84]`, a consistent ~1.5em row pitch. Rendered correctly, 3 stacked rows,
   confirmed by screenshot. **The basic multi-row mechanism works.**
5. **Complex 3-row `aligned`** approximating the actual repro (each row a
   full `\lim`/`\exp`/`\frac` derivation step, matching the shape of
   `math-ratex-padding-issue.png`'s content): `height=1.6`, `depth=1.1` (em,
   total 2.7em) — **smaller** than the simple case despite taller per-row
   content — and item Y values `[0.581, 0.768, 0.773, 0.862, 0.883, 1.2,
   1.278, 1.45, 2.136, 2.147]`, clustered within a 1.57em band. For content
   whose rows individually need more than ~1em of vertical room (a
   `\frac`/`\lim` stack is taller than a bare letter), spacing that doesn't
   expand to match reads as rows landing almost on top of each other.

## Root cause

**RaTeX's `aligned` (multi-row) layout doesn't expand inter-row spacing to
fit each row's actual content height** — a row containing a fraction, limit,
or `\exp` needs more vertical room than a plain-letter row, but RaTeX's
JSON output doesn't give it that room. This is visible directly in the
DisplayList JSON (item Y-coordinates too close together, `height`/`depth`
too small for the visual content), independent of anything Edmund does with
that JSON. Both reports are the same mechanism, different endpoints:

- **Edit mode**: `minimumLineHeight` is set to RaTeX's own (too small)
  `height + depth`, which isn't enough room for the true rendered content,
  so the next paragraph physically overlaps it.
- **Read mode**: the rows' Y-coordinates are compressed close enough
  together that they read as flowing on roughly one baseline rather than as
  visually distinct stacked lines — RaTeX's data, faithfully rasterized.

Not a bug in `RaTeXDisplayListRenderer` (Y-to-pixel conversion, canvas
sizing, and the y-up/y-down flip were all re-checked and are correct — the
simple 3-row test proves the pipeline handles well-formed multi-row input
correctly) and not the CSS-pixel-ratio issue from the weight investigation
(different files, different mechanism, confirmed non-interacting by
timing and by code path).

## The fix

None applied at the time. See Round 2 — the conclusion above did not hold up.

## Verification

- Direct JSON evidence (§ above) — item Y-coordinates and `height`/`depth`
  read straight from RaTeX's own output, not inferred from screenshots.
- Simple-case control test confirms Edmund's own rendering pipeline (Y flip,
  canvas sizing, row positioning) is correct — isolates the defect to
  RaTeX's row-spacing computation specifically, not general multi-row
  support.
- All debug instrumentation (`WasmMathHost`'s env-var JSON dump,
  `main.swift`'s `-debug.enableRaTeX`/`-debug.readMode` flags) was temporary
  and has been reverted — nothing shipped from this investigation.

### Honest limits

- Only tested with a hand-built approximation of the real repro's LaTeX
  (nested `\lim`/`\exp`/`\frac` per row), not the exact source from the
  user's actual document (not available in this repo). The mechanism and
  magnitude match closely enough to be confident in the root cause, but the
  precise LaTeX that produced `math-ratex-multiline-read-mode.png` wasn't
  re-run byte-for-byte.
- Didn't inspect RaTeX's Rust/WASM source (out of this repo, and not worth
  it given the dev has already signaled active work on related layout
  gaps) — the conclusion rests entirely on its observable JSON output, which
  is sufficient to place the bug upstream but doesn't explain *why* inside
  RaTeX's own layout code.

## If it ever recurs

Dump the DisplayList JSON first (temporary env-var hook in
`WasmMathHost.render()`, see § above for the exact line) before touching any
Edmund rendering code — if the Y-coordinates/height/depth are already wrong
in RaTeX's own output, no amount of changing `DisplayListRenderer` or the
paragraph-height reservation code will fix it.


---

# Round 2 (2026-07-28) — the root cause above is wrong

Re-opened when RaTeX 0.1.14 shipped, to check whether upstream had fixed
this. It hadn't, because there was nothing upstream to fix.

## What was wrong with Round 1

Round 1 compared **two different equations**, not one equation across two
versions. The "simple" control (`a &= b \\ c &= d \\ e &= f`) and the
"complex" case (a hand-built `\lim`/`\frac`/`\exp` derivation) were both
measured on 0.1.12 only, and the complex case's smaller `height`/`depth` was
read as the defect. That comparison can't support the conclusion: two
different LaTeX inputs are *expected* to produce different metrics, and no
version-to-version comparison was ever run.

## Head-to-head measurement

Same inputs, both versions, via the same `renderLatex` JSON the original
investigation dumped (`total` = `height + depth`, in em; *y-clusters* =
distinct item Y values grouped with a 0.6em gap threshold, i.e. how many
visually separated rows the display list actually contains):

| input | 0.1.12 | 0.1.14 |
|---|---|---|
| 4-row derivation, `\overset` + `\limits` (the screenshot's shape) | total 10.61em, yspan 9.96em, 7 clusters | total 10.31em, yspan 9.96em, 7 clusters |
| same, without `\overset` | total 7.83em, yspan 7.18em, 6 clusters | total 7.53em, yspan 7.18em, 6 clusters |
| plain 4-row `a &= b \\ …` | total 6.00em, yspan 4.50em, 4 clusters | total 5.70em, yspan 4.50em, 4 clusters |
| 3-row `\lim`/`\frac`/`\exp` (Round 1's own "complex" case) | total 8.10em | total 7.80em |

**0.1.12 already stacked every one of these correctly**, including Round 1's
own complex case, which measures 8.10em — not the 2.7em Round 1 recorded.
Row spacing tracks row content in both versions; the two differ by a uniform
~0.3em, which is the unrelated 0.1.14 layout-fidelity work, not row spacing.

No LaTeX that reproduces the collapse has been found on any version.

## What the screenshots probably were

Two mechanisms remain, both Edmund-side and both already addressed:

- **Read-mode collapse**: swift-markdown applies Markdown backslash-unescaping
  to a `Text` node's `.string` (`\\`→`\`), which deletes an `aligned`
  block's row separators outright — every row then lands on one line, exactly
  what `math-ratex-multiline-read-mode.png` shows. Fixed 2026-07-06 in
  `b1d5ede` by parsing math from raw source in `HTMLRenderer.visitParagraph`,
  and covered by `HTMLRendererTests` / `DocumentHTMLTests`. This is a much
  better fit for the evidence than a layout defect: it explains why *edit*
  mode stacked the same equation correctly (it reads storage by range and
  never goes through swift-markdown's unescaping) while read mode didn't —
  something a defect inside RaTeX could not explain, since both modes call
  the same engine with the same arguments. The screenshot is dated two days
  after that fix, so either it was taken on an older build or `sourceText`
  returned nil and hit the `?? plainText` fallback.
- **Edit-mode overlap**: display math's height reservation, since reworked —
  `displayMathParagraphStyle` now reserves `imageAscent` in
  `minimumLineHeight` and folds `imageDescent` into `paragraphSpacing`,
  rather than reserving one combined height that TextKit 2 puts entirely
  above the baseline.

## Status

**Not a bug. Not a ship blocker.** The Advanced Math extension is unblocked
on this axis. The genuine 0.1.14 requirement is the separate `displayMode`
argument (see `RaTeXRelease`), which *was* real and *is* fixed.

## What Round 1 should have done

Measure one input across two versions before attributing a defect to a
dependency. Round 1's "Honest limits" section flagged the exact weakness that
sank it — that the real repro's LaTeX was never captured — and the conclusion
was written as settled anyway. A control that shares no input with the case
under test isn't a control.
