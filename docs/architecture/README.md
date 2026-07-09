# Edmund architecture: developer overview

The human-readable tour of Edmund's internals. This doc is a summary: every
claim here points at the section or doc that owns it. If you're an agent
making a change fast, read [`../ARCHITECTURE.md`](../ARCHITECTURE.md)
instead; if you're a human getting oriented, start here.

## What Edmund is

A native macOS Markdown editor with live preview: AppKit + TextKit 2, built
with SwiftPM, targeting macOS 14+. Two SPM targets: `EdmundCore`, the
library that holds all editor logic (parsing, rendering, the
`EditorTextView`) plus the test suite, and `edmd`, the executable, an
`NSDocument` app shell (Settings, menus, window setup) that depends on
`EdmundCore`. Source: `../ARCHITECTURE.md` §1.

## The two invariants

Everything else in the codebase is built to hold these:

1. **Text storage always equals `rawSource`.** Rendering is attribute-only.
   Edmund never inserts or deletes display characters. Markdown delimiters
   are hidden (near-zero font, clear color), never stripped.
2. **TextKit 2 only.** The editor never touches `NSTextView.layoutManager`
   and never stores `NSTextBlock`/`NSTextTable` attributes. Either one
   silently and permanently reverts the view to TextKit 1.

The home of these rules is `../ARCHITECTURE.md` §2.

## Map of this folder

- [`editor-pipeline.md`](editor-pipeline.md): `rawSource` → parse → style →
  attributed storage, the recompose paths, lazy styling.
- [`text-system.md`](text-system.md): why TextKit 2 only, the custom
  layout-fragment decoration mechanism, hiding, the height-estimate and
  image-wedge constraints.
- [`extensibility.md`](extensibility.md): the themes/extensions design.
  **Design only, not yet implemented on `main`.**
- Planned, not yet written: `reader-and-export.md`, `edit-flow-and-undo.md`,
  `app-shell-and-settings.md`.

## Map of sibling folders

- [`../investigations/`](../investigations/): chronicles of hard bugs, one
  doc per bug class, written up round by round. `archives/` holds closed
  classes (fixed and not expected to recur); the rest are still active.
- [`../dev-guides/`](../dev-guides/): method docs (how to do something), not
  bug chronicles. Start with
  [`live-repro-guide.md`](../dev-guides/live-repro-guide.md) if you're
  reproducing a live-app bug.

## Quirks you'll hit

- **A "successful" build can be stale.** `swift build` sometimes prints
  `Build complete!` after compiling a changed file without relinking `edmd`,
  so you run old code. `../ARCHITECTURE.md` §8 has the detection/cure.
- **Delimiters are hidden, not stripped.** `**bold**` keeps its asterisks in
  storage; they're rendered near-invisible. This is invariant 1 above. Home:
  `../ARCHITECTURE.md` §2.
- **TextKit 2 height estimates cause most viewport glitches.** A fragment
  has a real frame only once laid out; everything else is an estimate that
  gets corrected as layout catches up. `../ARCHITECTURE.md` §8 covers the
  mitigations; the bug history is
  [`../investigations/viewport-glitch-investigation.md`](../investigations/viewport-glitch-investigation.md).
- **Images can't be drawn on wrapping (multi-line) layout fragments.**
  Drawing one collapses the fragment's layout to one line.
  `../ARCHITECTURE.md` §9; the full saga (and the stroked-path workaround)
  is
  [`../investigations/archives/callout-title-wrap-investigation.md`](../investigations/archives/callout-title-wrap-investigation.md).
- **Never mutate storage while an IME is composing.** Doing so can strand
  marked text and permanently break the storage==rawSource sync, which
  drifts the caret on every later edit. `../ARCHITECTURE.md` §8; the full
  investigation is
  [`../investigations/delete-drift-investigation.md`](../investigations/delete-drift-investigation.md).

## Getting started

```bash
swift build   # debug build of both targets
swift test    # full suite
```

Tests live in `Tests/EdmundTests`. Before committing, run the pre-commit
checklist in `../ARCHITECTURE.md` §12.
