# Editor pipeline — parsing to pixels

Expands `../ARCHITECTURE.md` §3 (render pipeline) and the styling half of §4
(edit flow). This doc narrates the mechanism; the invariant it serves
(storage always equals `rawSource`) is owned by `../ARCHITECTURE.md` §2.

## End-to-end narrative

```
rawSource ──BlockParser──▶ [Block] ──SyntaxHighlighter──▶ spans ──styleBlock──▶ attribute runs
```

1. **`BlockParser`** (`Sources/EdmundCore/Parsing/BlockParser.swift`) splits
   `rawSource` into `Block`s — one per logical unit: paragraph, heading, list
   item, quote/callout run, code fence, display-math block, table. It merges
   multi-line constructs (an opening fence until its closing fence, a run of
   `>` lines, a table's header+separator+rows) into single blocks via a
   lazy `LineBuffer` so both the full parse and the incremental parse (below)
   consume lines identically and can't diverge.
2. **`SyntaxHighlighter`** and its extensions (`+Walker`, `+WalkerInline`,
   `+CustomParsers`) walk a block's content and produce a flat list of
   `SyntaxHighlighter.Span`s — spans handle both CommonMark/GFM constructs
   (via `swift-markdown`'s walker) and Edmund's non-CommonMark syntax
   (callouts, `==highlight==`, wikilinks, footnotes, math, backslash escapes,
   inline HTML tags) through the custom parsers.
3. **`styleBlock(_:cursorPosition:)`**
   (`Sources/EdmundCore/Rendering/EditorTextView+Rendering.swift`) turns one
   block's spans into an `NSAttributedString` covering the *same* characters
   as the raw markdown — never a stripped version. Each feature has its own
   `Rendering/` extension (Callout, Code, Image, List, ListMarker, Math,
   Table, WikiLinks) that `styleBlock` dispatches into per span kind.
   Delimiters get attribute treatment, not deletion: `hiddenFont`
   (`NSFont.systemFont(ofSize: 0.01)`) plus a clear foreground color makes a
   token's `**`/`` ` ``/`[!note]` markers occupy zero visible space without
   removing them from storage.

## The three recompose paths

`Sources/EdmundCore/TextView/EditorTextView+Composition.swift` is the single
place that writes styled attributes into the text storage. Three entry
points, each used for a different class of change:

- **`recompose(cursorInRaw:)`** — full: replaces the *entire* text storage
  with `rawSource` in base attributes, then restyles every block. Used when
  `rawSource` was rebuilt outside the edit path: initial load, undo/redo,
  indent. Expensive — it discards every TextKit 2 layout fragment, resetting
  all geometry to estimates (see `text-system.md` and
  `../investigations/viewport-glitch-investigation.md` for why that matters).
- **`recomposeDirty(_:cursorInRaw:)`** — the workhorse: restyles exactly the
  given set of block indices in place. Attribute-only; the storage string
  itself is never touched. This is the single styling path for edits,
  activation changes (cursor moving in/out of a block), and theme/appearance
  refreshes.
- **`recomposeIncremental(cursorInRaw:)`** — restyles just the old and new
  active blocks when the cursor moves between blocks without changing
  content; a thin wrapper around `recomposeDirty`.

A fourth entry point, `recomposeReplacing(oldRange:with:dirty:cursorInRaw:)`,
handles edits that rebuild a contiguous span of `rawSource` without a full
replace (Tab/Shift-Tab indent) — it string-replaces only that span, so
storage outside it (and its TextKit 2 layout) is untouched and the viewport
can't lurch.

**Active-block raw reveal**: the block under the caret renders its *raw*
markdown — delimiters visible and editable. Every other block renders
styled. `recomposeDirty` computes this by tracking `activeBlockIndex` and
passing a `cursorInBlock` offset into `restyleBlock` for the active block
only; that offset drives which token's delimiters get revealed vs. hidden as
the cursor moves within the block (`+SelectionTracking`).

## Lazy styling: idle drain + scroll promotion

`recomposeDirty` doesn't always style its whole dirty set synchronously. A
**large** dirty set (initial load, a theme change, a fence edit that
re-absorbs half the document) is capped to a window near the TextKit 2
viewport (`syncStylingBlockRange()`, with a margin) plus the active block; a
**small** dirty set (any ordinary interaction) is styled in full, so
user-visible state transitions are never deferred. Without a scroll view
(headless), everything is synchronous.

Blocks left out of the synchronous set are marked unstyled and converge via
two mechanisms in `Sources/EdmundCore/TextView/EditorTextView+LazyStyling.swift`:

- **The idle drain** (`drainStylingSlice`): time-budgeted (~6 ms) main-thread
  slices that restyle unstyled blocks, resuming from where the last slice
  stopped, until none remain. Runs off `scheduleProgressiveStyling`,
  coalesced and re-entrant-safe.
- **Scroll promotion** (`promoteVisibleUnstyledBlocks`, driven by
  `clipViewBoundsDidChange`): as the clip view scrolls, unstyled blocks
  entering the viewport window are styled synchronously so the user never
  sees raw base-attributed text scroll into view.

This exists for large-document responsiveness: styling the whole document
synchronously on load or on a document-wide theme change would stall the
main thread; lazy styling keeps the viewport interactive immediately and
finishes the rest in the background.

## Incremental parsing window

`EditorTextStorage` (`Sources/EdmundCore/TextView/EditorTextStorage.swift`)
is the `NSTextStorage` subclass backing the editor. Every `replaceCharacters`
call — typing, paste, IME commit — accumulates a `PendingEdit` (old-string
range + length delta), coalescing multiple mutations within one event turn
into their conservative hull. This is the single funnel `didChangeText`
reads to drive `BlockParser.incrementalParse`, which re-splits only the
affected lines (O(edit), not O(document)) instead of re-parsing the whole
document on every keystroke. A `#if DEBUG` oracle
(`verifyIncrementalParse`) cross-checks every incremental result against a
from-scratch parse. Programmatic whole-document replacements (`recompose`
after load/undo/indent) call `clearPendingEdit()` since they re-parse from
scratch themselves — the incremental path is never asked to reconcile a
change it didn't see.

## Worked example: typing one character inside a callout

1. NSTextView calls `shouldChangeText(in:replacementString:)` — Edmund
   records an undo snapshot and returns `true`.
2. NSTextView mutates the storage (`EditorTextStorage.replaceCharacters`),
   which accumulates the edit into `pendingEdit` and calls `edited(...)`.
3. NSTextView calls `didChangeText()`
   (`Sources/EdmundCore/TextView/EditorTextView+EditFlow.swift`). Guarded by
   `!isUpdating` and `!hasMarkedText()` (never touch storage mid-IME-
   composition — see `../ARCHITECTURE.md` §8), it calls
   `syncRawSourceFromDisplay()`.
4. `syncRawSourceFromDisplay` re-reads `rawSource` from storage, consumes the
   storage's `pendingEdit`, and calls `BlockParser.incrementalParse` — for a
   single character typed inside an existing callout block, the edit range
   sits entirely inside that one block, so the incremental parse re-splits
   just the callout's quote run (and, per the parser's lookback rule, the
   block immediately before it) and returns a `changed` window of one index.
5. The dirty set is built from that changed window plus the old/new active
   block (usually the same index here) and any list-indent-affected blocks
   (none, for a callout edit).
6. `recomposeDirty` restyles exactly that block: `styleBlock` re-runs
   `SyntaxHighlighter` on the callout's new content and produces fresh
   attribute runs — the callout box decoration, header icon overlay, and
   body text styling are all re-derived, not incrementally patched. TextKit 2
   layout is invalidated for the restyled block's range so the box's height
   picks up the new line if the character wrapped.
7. If the edit's caret math and TextKit 2's queued selection fixup disagree
   (see the delete-drift investigation), the caret is re-asserted after the
   restyle.

No other block is touched, and the storage string outside the callout was
never replaced — only its attributes changed.
