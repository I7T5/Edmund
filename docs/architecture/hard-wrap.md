# Hard wrap

`Editing/HardWrap.swift` (pure `wrap`/`unwrap`) +
`Editing/EditorTextView+HardWrap.swift` (Edit ▸ Hard Wrap Paragraphs).

Settings ▸ Edit ▸ Document ("Detect hard wrap pattern for lines on document
opening"), off by default — one switch for the whole feature; read at **load/save
time in `Document`**, not pushed onto the editor. Like `strictLineBreaks` there
is no live editor behavior to configure.

`ARCHITECTURE.md` §6 owns the one-line statement; this doc owns the mechanism.

## Hard wrap is a property of the file, not the buffer

Opening a hard-wrapped file joins each paragraph's soft-broken lines so editing
works on one long logical line, and `data(ofType:)` re-wraps on the way out — so
the buffer deliberately differs from the file on disk.

**Only files that arrived wrapped are wrapped.** `EditorTextView.wasHardWrapped`
is set when the join on open actually changed the text, which is exactly the
signal that the file had wrapping; a file of long single lines is written back
verbatim, and the menu command is the only way to wrap it.

The menu command rebuilds `rawSource` and goes through `recomposeReplacing` (the
Tab/Shift-Tab route, one undoable step). It deliberately does **not** set
`wasHardWrapped`, which describes the file rather than the buffer — setting it
would make undo look broken, since the text would revert but the next save would
wrap it straight back.

## Ordering constraints

The unwrap runs *inside* `loadContent`, after `LineEnding.detect` / `normalize`:
doing it in `Document` would hand the detector text whose CRLFs were already
rewritten, and silently convert every CRLF file to LF.

It requires strict line breaks (the checkbox greys out without it): with those
off a single newline renders as a literal `<br>`, so joining would delete visible
breaks and wrapping would invent them.

## What gets rewritten

Only `.paragraph` blocks — every other kind is copied through, so fences, tables,
headings and front matter are safe by construction. Because plain text parses
**one `.paragraph` block per source line**, the transform runs over *runs* of
consecutive paragraph blocks rather than block by block.

Two GFM rules the fill has to respect:

1. A two-space or unescaped-backslash line ending is a **hard break** (content,
   not formatting) and bounds a segment in both directions.
2. A break is **refused in front of a block-opening token** (`#`, `>`, `-`,
   `1.`, `|`, fences …) because a greedy fill would otherwise turn
   "…costs 1. 50 per unit…" into an ordered list on the next parse — the line
   overflows instead.

## The width is the file's own, and it is derived rather than guessed

`detectColumn` → `EditorTextView.hardWrapColumn`, so a file wrapped at 72 isn't
reflowed to 80 on its first save.

The longest line would undershoot the real column by however much the next word
overhung, so the existing breaks are read as **constraints** instead: every line
had to fit (`column >= len(line)`) and every break had to be forced
(`column < len(line) + 1 + len(next word)`). That leaves a *range* of columns
which all reproduce the file's breaks exactly.

The pick therefore only affects text typed later — and the endpoints are both
wrong for that. Taking the low end shaves a few characters off on every save and
creeps the document narrower, so a conventional width (80, 100, 120, 72, 60) is
preferred when one qualifies, with the widest consistent column as the fallback.

## Cost

**All parsing.** The transforms themselves are single-digit ms, while
`BlockParser.parse` is ~95% of the time — so open takes `unwrapDetectingColumn`,
which gets the join *and* the column off one parse rather than two.

Measured (release): +2 ms on a 5 KB note, +14 ms at 30 KB, +74 ms on
`ARCHITECTURE.md` itself, +0.6 s on a 1.3 MB document; save is one more parse.
Nothing is paid at all with the setting off, which is the default.
