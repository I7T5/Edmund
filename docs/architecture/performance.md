# Performance

How Edmund stays fast on long documents, the rules that keep it fast, and how
to measure a change. The `perf-reviewer` agent (`.claude/agents/`) checks every
shipped diff against §2. `ARCHITECTURE.md` §6 and §8 own the individual
mechanisms; this doc owns the rules and the measurements behind them.

## 1. Where the time went

Measured on a 1 MB document (~1,400 footnote and link definitions, ~340
tables), release build, before and after the 2026-09/10 performance work
(PR #383):

| Path | Before | After | Cause |
|---|---:|---:|---|
| Full lazy-styling drain | 642 s | 2.4 s | List-depth map rebuilt over all blocks per styled block |
| Restyle every block | 61 s | 1.5 s | All link definitions appended to every block's parse |
| Open (main thread busy) | >4.5 s | 0.64 s | Whole-document synchronous spell check |
| Wheel-scroll tick, p50 | 44 ms | 2.3 ms | Drain competing with scroll; margin chrome scanning all blocks |
| First scroll after open, worst frame | 156 ms | 29 ms | Promotion's sync spell recheck waiting on the async scan |
| Drag across table cells, per event | 238 ms | 0.1 ms | Hit test forced layout on every table |
| Caret in a table, per draw | 15 ms | 4 µs | `ensureLayout` from the document start on every draw |
| Zoom / font size step | 122 ms | 46 ms | Each attribute lookup bridged the whole attribute dictionary |
| Light/dark switch | 250 ms | 95 ms | Same, plus a sync spell recheck |
| Read-mode HTML build | 1.31 s | 0.70 s | Quadratic UTF-16 offset sums |

The lesson: **almost none of it was TextKit 2's height estimates.** It was
whole-document loops on paths that run per block, per keystroke, per draw or
per scroll tick. CodeMirror 6 (MarkEdit) is fast because its work scales with
the edit and the viewport, never the document; the same rule holds here.

## 2. Rules

Each rule names the incident it came from. A change that breaks one needs a
measurement showing the cost is bounded, or a comment naming the ceiling.

1. **No whole-document work on a hot path.** Hot paths: per block (restyle,
   drain slice, promotion), per keystroke, per draw (`draw`, `drawBackground`,
   fragment vend), per scroll tick or bounds change, per mouse move or drag
   event, per caret blink. "Whole document" includes loops over `blocks`,
   `rawSource`, the text storage, `lineStarts`, all tables or all link
   definitions. Bound the walk to the viewport or the edit:
   `blockIndexForRawOffset(_:)` gives the first block; break past the last.
   (Margin chrome scanned every block per draw; the table hit test laid out
   every table per drag event.)
2. **Don't invalidate a cache the change doesn't affect.** A `didSet` that
   drops a cache fires on every element write, including flags. Styling never
   changes list depth, so `isStyled` goes through `setStyled(_:_:)`, which
   keeps `listDepthsCache`. (Assigning `blocks[i].isStyled` rebuilt the depth
   map once per styled block: 1,398 builds per drain.)
3. **Per-block inputs must be per-block.** Don't append document-wide context
   (all link definitions, all footnotes) to each block's parse. Pass only what
   the block references: `LinkDefinitionState.definitions(for:)`. (61 s → 1.5 s.)
4. **Derived state is stored, not recomputed per access.** A computed property
   that sorts, joins or scans, read inside a per-block loop, is quadratic.
   (`defsText`; `HTMLRenderer`'s offset sums, now the `lineUTF8Starts` table.)
5. **Never force layout on a draw, hit-test or blink path.** `ensureLayout`
   over a range costs a full pass above 100k (`fullLayoutMaxLength`), even when
   nothing is invalid. Gate it on a model fact first (the table caret checks
   `.tableCellWraps` on the row before measuring).
6. **Storage access goes through the overrides.** `EditorTextStorage`
   overrides `attribute(_:at:effectiveRange:)`, `attributes(at:…)` and
   `attributedSubstring(from:)`; without one, each call bridges or copies the
   whole document (#343, the zoom/appearance fix). Don't read
   `textStorage.string` in a loop; use `rawSource` or the `NSString` once.
7. **Styling-only restyles skip the spell recheck.** Zoom, appearance, theme,
   view mode, engine change, width and scroll promotion change attributes, not
   words. Wrap them in `stylingOnly { … }`. NSSpellChecker serializes
   requests: a synchronous check waits for the in-flight async chunk, so a
   stray recheck on a scroll path stalls a frame. Whole-document spell work is
   async (`requestSpelling`, 8 KB chunks, generation-cancelled).
8. **Restyle only what a setting changes.** Edit↔Read restyles the active
   block plus comment and `^` blocks; an engine change restyles only `$` and
   fence blocks. A full `recompose` is for content changes.
9. **Scheduled UI work runs in common modes.** `RunLoop.main.perform` without
   `inModes: [.common]` doesn't run while the scroller knob is dragged
   (`.eventTracking`), so promotion stalls and raw Markdown shows.
10. **Edits above the viewport are anchored.** A drain slice or restyle that
    changes heights above the visible text runs whole inside
    `preservingViewportAnchor`, edits included, and ends with
    `layoutViewport()`. Anchoring only the invalidation does nothing: TextKit 2
    re-estimates at `endEditing`. (Zoom drift.)
11. **Memoize expensive pure results on an input key.** Read mode skips the
    HTML rebuild when the source and options are unchanged
    (`ReadModeWebView` `LoadInputs`), and skips appearance reloads while hidden.
12. **Cheap prefilters before regexes.** The autolink regex runs only on text
    containing `@`, `://` or `www.`. `String.contains("\r\n")` is a Unicode
    (Character) search; scan UTF-8 bytes instead.

## 3. Measuring

- **Harness.** `PerfHarnessTests` + `scripts/bench.sh`. Compare against the
  base ref in a release build:

  ```sh
  MD_PERF_DRAIN=1 MD_PERF_BYTES=50000,300000,1000000 scripts/bench.sh origin/main
  ```

  Narrow with `MD_PERF_CASES='mixed/default'`; `MD_PERF_REPS=3` for anything
  close. Differences under ~10% are noise; the footprint column is noise at
  1–3 reps.
- **Probe tests** for what the harness doesn't time (mode switch, zoom,
  appearance, hit tests, one function): a throwaway `@Test` in a release build
  (`swift test -c release -Xswiftc -enable-testing --filter <Probe>`) that
  loads a 1 MB document (`PerfCorpus.document("mixed", bytes: 1_000_000)`, or
  a real file), runs `drainAllStyling`, and times the call with
  `ContinuousClock`. Synthetic corpora miss density effects: the 61 s restyle
  only showed on a file with ~1,400 definitions. Keep probe files out of
  `Tests/` when running the full suite: a 1 MB probe makes it time out.
- **Model real scrolling.** Programmatic scroll skips #355's live-scroll gate;
  post `NSScrollView.willStartLiveScrollNotification` first. Pace frames at
  16 ms to see stalls rather than throughput.
- **Live.** `sample <pid>` on the release app catches main-thread waits a
  headless run can't (spell-server locks, WebKit). WKWebView never finishes
  loading in the test process, so Read mode's WebKit time needs a live trace.
- **Regime.** State whether a number is ≤100k (full layout, real geometry) or
  above it (estimates). Use a 1 MB document for anything on a hot path.

## 4. Open

- The zoom step itself lands ~56 lines off in the live app (also before #383);
  headless zoom holds, so it needs a traced live repro.
- WebKit's share of the first Read render is unmeasured.
- Rows whose table cells wrap still pay `ensureLayout` on the draw path.
- Find-bar open: whole-document rescan per keystroke (`FindController`).
- Per-keystroke `lineStarts` rebuild; whole-fence re-tokenize when typing in a
  very large fence.
- Line numbers on: `layout()` dirties the whole strip; the find pop and copy
  flash dirty the whole view per frame.
- HTML build off the main thread (math and Mermaid renderers aren't known to
  be thread-safe); dynamic colors to avoid restyling on appearance flips.
- Pinch-to-zoom: scale with scroll-view magnification during the gesture and
  commit the font size once at the end.
