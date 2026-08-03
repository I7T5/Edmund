# Edmund — architecture & agent onboarding

Native macOS Markdown editor with live preview (AppKit + TextKit 2, SPM,
macOS 14+). Read this before any non-trivial change. **Keep it updated** —
when you learn something non-obvious or change an invariant, edit this file
in the same PR.

This is the agent-oriented canonical summary — dense, terse. Humans wanting
the narrative write-up start at
[`docs/architecture/README.md`](architecture/README.md); the same-PR update
rule applies to both.

---

## 1. Build / run / test

```bash
swift build                 # debug build of both targets
swift test                  # full suite (≈1200 tests, ~10s)
swift test --filter Callout # one suite
./scripts/build-app.sh      # builds build/Edmund.app (release + bundles + icon + codesign)
```

Run the app for visual checks (gotchas in §8):
```bash
pkill -x edmd; build/Edmund.app/Contents/MacOS/edmd /path/to/file.md &
```

Two SPM targets (`Package.swift`):
- **`EdmundCore`** — library: all editor logic, parsing, rendering,
  `EditorTextView`. Has the tests. **Most work happens here.**
- **`edmd`** — executable: `NSDocument` app shell, Settings (SwiftUI), menus,
  window setup.

Dependencies: `swift-markdown` (CommonMark/GFM), `SwiftMath` (LaTeX),
`Sparkle` (auto-update).

---

## 2. The two non-negotiable invariants

Break either and the whole editor misbehaves in subtle ways.

1. **Text storage always equals `rawSource`.** Rendering is *attribute-only*
   — never insert/delete display characters. Delimiters (`**`, `` ` ``,
   `[!note]`, …) are *hidden* (near-zero font + clear color), never stripped.
   Consequences: no `NSTextAttachment` (TextKit 2 only honors them on U+FFFC,
   which `rawSource` never contains — images/icons are drawn as overlays
   instead, §5); display offset == raw offset (identity mapping).

2. **TextKit 2 only.** Never touch `NSTextView.layoutManager`, never store
   `NSTextBlock`/`NSTextTable` attributes — either silently reverts the view
   to TextKit 1 for good. A DEBUG tripwire asserts if TK1 engages. Layout is
   viewport-based (only on-screen content laid out) — that's what makes big
   documents fast.

---

## 3. Rendering pipeline (the core loop)

```
rawSource ─BlockParser─▶ [Block] ─SyntaxHighlighter─▶ spans ─styleBlock─▶ attributes in storage
```

- **`BlockParser`** (`Parsing/`) splits `rawSource` into `Block`s (paragraph,
  heading — ATX or setext, list run, quote/callout run, code fence, indented
  code run, table…). `Block.kind` is a `BlockKind` enum (e.g.
  `.quoteRun(isCallout:)`). Indented code is the parser's only
  backward-looking rule (a run starts only after a blank line), so
  `consumeBlock` carries `prevLine` and the incremental parse won't resync
  onto an indented-code-ish line. Lists are one block per line, except a list
  item whose content opens an unclosed `$$` merges its `$$…$$` display-math run
  (forward, like the fence rules) so the span can form across lines.
- **`SyntaxHighlighter`** + `+Walker`/`+WalkerInline`/`+CustomParsers`
  produce styling spans. Custom parsers handle the non-CommonMark syntax:
  callouts, `==highlight==`, wikilinks, `%%` and `<!-- -->` comments,
  footnotes, math, backslash escapes, inline HTML tags incl. `<img>`, GFM
  autolinks.
- **`styleBlock(_:cursorPosition:)`** (`Rendering/EditorTextView+Rendering.swift`)
  renders ONE block. Each feature has a `Rendering/` extension: Callout,
  Code, Image, List, ListMarker, Math, Table, WikiLinks.
- **Recompose** (`TextView/EditorTextView+Composition.swift`) drives styling:
  - `recompose(cursorInRaw:)` — full: replace storage with rawSource, restyle
    all blocks (load, undo, indent).
  - `recomposeDirty(_:cursorInRaw:)` — restyle a set of block indices in
    place (the workhorse; attribute-only).
  - `recomposeIncremental(...)` — restyle just the block(s) the cursor moved
    between (most cursor moves).
  - **Active block**: the block under the caret renders its *raw* markdown
    (delimiters visible/editable); all others render styled.
- **Lazy styling** (`TextView/EditorTextView+LazyStyling.swift`): a large
  dirty set styles only the viewport synchronously; the rest is finished by
  the **idle drain** (time-budgeted main-thread slices) and **scroll
  promotion** (style blocks as they enter the viewport). Keeps large docs
  responsive.

---

## 4. Edit flow & undo

- Edits go through NSTextView's normal path: `shouldChangeText` records a
  coalesced undo snapshot → NSTextView mutates storage → `didChangeText`
  syncs `rawSource` and restyles the edited block(s) (`+EditFlow`,
  `+Composition`).
- **Incremental parsing**: edits capture a pending edit on
  `EditorTextStorage`; reparse a window, not the whole doc.
- **Undo/redo** is custom: stacks of `rawSource` snapshots (`+Undo.swift`),
  bypassing NSTextView's undo. Restore *diffs* the snapshot against current
  text (`textDiff`, single contiguous span) and applies it via the
  range-bounded `recomposeReplacing` — never a full `recompose`, which would
  reset every fragment to a TK2 height estimate and make the follow-up
  scroll land wrong. The changed text is selected (caret at the deletion
  point for pure deletions) and drives the viewport: hold if any of it is
  on-screen, else center it. The snapshot's stored caret is only a fallback
  for a no-op diff.
- **Cursor tracking** (`+SelectionTracking`): moving between blocks restyles
  both; moving within a block updates which token's delimiters are revealed.

---

## 5. TextKit 2 specifics (how visuals are drawn)

- **`DecoratedTextLayoutFragment`** (custom `NSTextLayoutFragment`,
  `+TextKit2.swift`) draws two custom attributes behind/over the text:
  - **`.blockDecoration`** (paragraph-level): callout boxes, quote bars,
    table borders, thematic-break rules, code-block backgrounds. Fragments
    tile vertically, so a multi-line run renders as one continuous box/bar.
    A box's `bottomPad` grows the *last* fragment's frame (TK2 omits
    trailing paragraph spacing from the fragment; draw-time-only padding
    would be dead space).
  - **`.fragmentOverlay`** (character-level): an image *or stroked vector
    path* drawn at a character's laid-out position — rendered math, list
    bullets/checkboxes, callout header icon+name image, custom-title callout
    icon (path). The anchor glyph is hidden and `.kern` reserves the
    drawing's advance width (same trick as the table renderer).
- **Hiding** text = `hiddenFont` (≈0.01pt) + clear `foregroundColor` — how
  delimiters and in-source markers vanish without changing the string.
- **Dark-mode chrome palette** (`+ListRendering.swift`): the system semantic
  colors are too faint on the `#292929` background, so dark mode substitutes
  fixed sRGB grays and Read mode's CSS vars carry the same values, so the two
  views match pixel-for-pixel. `syntaxDimColor` (the whole dim tier —
  delimiters, `%%comments%%`, `^blockrefs`, list markers, quote bars) →
  `darkChromeGray` #696969 = `--marker`; table borders → `darkRuleGray`
  #555555 = `--table-border`; the `---` rule → `darkHRuleGray` #4a4a4a =
  `--hr`; body text → #e6e6e6 = `--fg`; code backgrounds #333333 = `--code-bg`
  with inline code a step above at #3c3c3c = `--inline-code-bg`. Light mode
  keeps the semantic colors. Build these with `srgbRed:`, **not**
  `NSColor(hex:)` or `calibratedWhite:` — the calibrated space renders visibly
  lighter than the hex it was given (same trap as `editorBackgroundColor`).
- **Hairlines are filled, not stroked.** A 1pt stroke straddles a pixel
  boundary and covers *two* device rows on Retina, so stroked table verticals
  read twice as heavy as the row rules beside them. Table column borders fill
  exactly one device pixel and the `---` rule fills three. The backing scale
  comes from `context.convertToDeviceSpace(CGSize(width: 1, height: 1))` —
  `context.ctm.a` reports 1 even at 2x.
- **Image overlays only work on single-line fragments.** An *image* on a
  *multi-line* (wrapping) fragment re-triggers a layout pass that wedges it
  to one line; a *shape* does not. So the wrapping callout custom title's
  icon is a stroked `CGPath` (`SVGPath` parses the vendored Lucide
  geometry), never an image — see
  `docs/investigations/archives/callout-title-wrap-investigation.md`.
- **Repeated immutable overlays are process-cached.** List markers, callout
  headers/icons, and identical math overlays must reuse the same
  `FragmentOverlay` value across editor instances. Creating one per block
  grows Foundation's process-wide weak attribute-dictionary intern table and
  makes later lazy-styling slices progressively slower. Cache keys include
  every visual/metric input, and the `NSCache`-backed marker caches are bounded.
- **Custom attributed-string values need discriminating hashes.** Value
  equality paired with constant-by-kind/count hashes turns Foundation's global
  attribute-dictionary interner into a collision chain and makes styling
  superlinear. Hash every field used by equality whenever the value permits it.

---

## 6. Feature map (where to look)

| Area | Files |
| --- | --- |
| Editor core / state | `TextView/EditorTextView.swift` (+ many extensions) |
| Parsing | `Parsing/BlockParser.swift`, `SyntaxHighlighter*.swift`, `CodeHighlighter.swift`, `CodeSyntaxPalette.swift` (shared Tomorrow/One-Dark hex table — read by both the editor's `NSColor` palette and the HTML CSS generator) |
| Code-fence highlighting | A pluggable seam, not a hardcoded scanner. `CodeHighlighter` is the facade: it resolves the effective language, then hands `(code, language)` to the active `CodeSyntaxBackend`. `BuiltinSyntaxBackend` is the default — one single-pass O(n) char scanner driven by a declarative `LanguageDefinition` (keywords, comment/string delimiters) rather than per-language code. `SyntaxDefinitionStore` loads those definitions from two places: the bundled JSON in `EdmundCore/Resources/Syntaxes/` and the user's Application Support dir, so **users can add a language without a rebuild**. Settings ▸ Syntax picks the fallback language (`settings.syntax.defaultCodeSyntax`). |
| Block model | `Model/Block.swift`, `Callout.swift`, `EditorTheme.swift`, `ListIndentState.swift`, `LinkDefinitionState.swift` (incremental index of `[label]: dest` reference-link definitions, which resolve across blocks — so a definition edit dirties the blocks that cite it), `LineEnding.swift` (buffer is always LF internally so `BlockParser`'s `\n` split stays clean; the file's original CRLF/CR style is remembered and written back on save), `StatusBarPrefs.swift`, `SVGPath.swift` (minimal SVG→`CGPath` for the vendored Lucide geometry — §5's wrapping-callout icon) |
| Text storage | `TextView/EditorTextStorage.swift` — `NSTextStorage` subclass whose `fixAttributes` does **font substitution only**. The editor manages every attribute on every character (incl. custom keys like `.blockDecoration`/`.fragmentOverlay`), so AppKit's usual attribute fixing would fight it. Also carries the `pendingEdit` that drives incremental reparse (§4) and the bypassed-edit heal (§8). |
| Markdown feature toggles | `Model/MarkdownFeatures.swift` — one `OptionSet` (`.all` default) gating each extension (highlight, `%%`comment, callout, wikilink, footnote, math, image dimensions `\|WxH`, `![[embed]]`, collapsible callouts `[!x]-/+`, plus Phase-2 front-matter/tag/blockRef/multi-block-comment). Threaded into `SyntaxHighlighter.parse(features:)` (gates each custom-parser pass; callout gated at render via `calloutInfo`), `EditorTextView.markdownFeatures` (didSet recompose), and `ReadRenderOptions.features` (→ `HTMLRenderer`). Assembled from per-feature UserDefaults toggles by `AppSettings.markdownFeatures`; Settings ▸ Syntax pane. A cleared flag renders the syntax as plain text in **both** back-ends. |
| Rendering | `Rendering/EditorTextView+*Rendering.swift` (Callout, Code, Image, List, Math, Table, WikiLinks) |
| Invisible characters | `TextView/EditorTextView+Invisibles.swift` — faint marks (· → ¬ ␣ ▯) overdrawn on laid-out whitespace, riding `DecoratedTextLayoutFragment.draw`. Pure display overlay: no characters inserted, TextKit 2 only. `EditorTextView.invisibles` ← `AppSettings.invisiblesConfig`; Settings ▸ Edit. Mechanism: [`architecture/editor-affordances.md`](architecture/editor-affordances.md). |
| List indent guides | Faint vertical hairlines on list items: one per *ancestor* level spanning the item, plus the item's own column beside its wrapped continuation lines. Offsets from `listGuideOffsets(depth:slotWidth:)` (`Rendering/EditorTextView+ListRendering.swift`), written to `.listGuides` **whether or not the setting is on** — the fragment gates the drawing, so toggling is a re-vend, never a restyle. `EditorTextView.showListIndentGuides`; Settings ▸ Edit. Geometry traps (container-relative offsets, `lineFragmentPadding`): [`architecture/editor-affordances.md`](architecture/editor-affordances.md). |
| Line numbers | `TextView/EditorTextView+LineNumbers.swift` — source line numbers (Settings ▸ Edit ▸ Lines, off by default), `EditorTextView.showLineNumbers`. **Two placements over one walk**, and the placement is **not** a setting: it follows whether the margin can hold them (beside the content by default, a `LineNumberRulerView` at the window edge otherwise). Also home to `line(forOffset:)`/`offset(forLine:)`, binary-searching the cached `lineStarts`. Editor-only; never printed. Placement rules, the macOS 14 SIGSEGV, draw rules and the tabular-figure face: [`architecture/editor-affordances.md`](architecture/editor-affordances.md). |
| Focus mode | `TextView/EditorTextView+FocusMode.swift` — dims all but the lines the selection touches (Settings ▸ Edit ▸ Editor, View ▸ Focus Mode; off by default), `EditorTextView.focusMode`. **One transparency layer around `DecoratedTextLayoutFragment.draw`**, so text and its decorations fade as one composite; it cannot be a scrim (NSTextView composites fragments *after* `draw(_:)` returns). Editor-only. Why, and the measurements: [`architecture/editor-affordances.md`](architecture/editor-affordances.md). |
| Read mode / Export | `Export/` — `HTMLRenderer` (MarkupVisitor → HTML; callout/checkbox icons are inline Lucide SVGs from `LucideIcons`), `HTMLTheme` (EditorTheme → CSS), `DocumentHTML` (assembly + asset inlining: math + local images → data URIs), `ReadModeWebView`, `MarkdownPrinter` (PDF/Print). `Document.refreshReadView()` keeps an open Read view in sync with edits and theme changes. |
| Icons | `Model/LucideIcons.swift` — vendored [Lucide](https://lucide.dev) SVGs (ISC, `LICENSES/lucide.txt`). Callout headers use them in **both** modes: Read inlines the SVG (CSS-tinted via `currentColor`); Edit rasterizes to a tinted `NSImage` overlay. SF Symbols can't ship in exported PDFs (license); app-chrome SF Symbols are fine (in-app UI). Edit-mode task checkboxes still use SF Symbols (on-screen only); Read-mode checkboxes are a composed Lucide SVG. |
| Edit behaviors | `Editing/EditorTextView+{List,Blockquote}Continuation.swift`, `+Indentation.swift`, `+AutoPairs.swift`, `+ListRenumbering.swift` |
| Hard wrap | `Editing/HardWrap.swift` (pure `wrap`/`unwrap`) + `Editing/EditorTextView+HardWrap.swift` (Edit ▸ Hard Wrap Paragraphs). Settings ▸ Edit ▸ Document, off by default; read at **load/save time in `Document`**, not pushed onto the editor. Treated as a property of the *file*: opening a wrapped file joins its paragraphs, save re-wraps, and **only files that arrived wrapped are wrapped** (`wasHardWrapped`). The column is **derived from the file's own existing breaks**, not guessed. Requires strict line breaks. Full rules, GFM constraints and perf numbers: [`architecture/hard-wrap.md`](architecture/hard-wrap.md). |
| Formatting commands | `Editing/EditorTextView+Formatting{Core,Commands}.swift` (Format-menu actions); menu built from `edmd/App/FormatMenu.swift` |
| Lazy/compose/undo/scroll | `TextView/EditorTextView+{Composition,LazyStyling,Undo,TypewriterScroll,SelectionTracking,ContentWidth,EditFlow}.swift` |
| App shell | `edmd/App/{main,Document,DocumentController}.swift`; menu bar in `main.swift` `setupMenuBar()` + `FormatMenu.swift`; Sparkle `SPUStandardUpdaterController` in `AppDelegate` |
| macOS integrations | Services menu (`edmd/App/ServicesProvider.swift` + `NSServices` in `Info.plist`), App Intents (`edmd/App/Intents.swift`), Quick Look preview (`EdmundQuickLook` target, hosts `ReadModeWebView`), AppleScript code-fence syntax (`EdmundCore/Resources/Syntaxes/applescript.json`). **Two shipped-but-not-live-verifiable limitations** (App Intents metadata needs an Xcode-project build; the Quick Look appex won't launch under ad-hoc signing): [`architecture/macos-integrations.md`](architecture/macos-integrations.md). |
| Settings (SwiftUI) | `edmd/Settings/*` (AppSettings = UserDefaults keys; FontSettings; Appearance/General/Advanced views) |
| Key bindings | `edmd/Settings/KeyBindingStore.swift` + `KeyBindingsSettingsView.swift`. Every rebindable command is a `MenuCommand` (`App/FormatMenu.swift`) with a stable `id`, a `group` (the menu it lives under) and a default `Shortcut`; `makeItem()` resolves the user's override from `KeyBindingStore` and registers the built `NSMenuItem` in `KeyBindingCatalog`, so the pane retunes shortcuts live without rebuilding the menu bar. Overrides live in one UserDefaults dict (`settings.keyBindings`, `id → "shift+cmd+e"`); an empty string means "user removed this shortcut", a missing key means "use the default". Conflicts are checked against the **live `NSApp.mainMenu`**, not the catalog, so system items (⌘S, ⌘C) count too; a chord without ⌘ or ⌃ is refused outright (it would fire while typing). Only Edmund's own commands are listed — the OS-standard items stay fixed. |
| Crash-log uploading | `EdmundCore/Diagnostics/CrashReporter.swift` (§7) |
| Auto-update | Sparkle 2.x. `Info.plist`: `SUFeedURL` (raw GitHub URL to `appcast.xml`), `SUPublicEDKey`. `scripts/release.sh`: build → DMG (sindresorhus `create-dmg`, **npm** — not the homebrew tool) → EdDSA sign → update appcast → `gh release create`. The DMG is the Sparkle enclosure. CI: `.github/workflows/release.yml` (tag-triggered). Full pipeline + signing + `RELEASE_TOKEN`: §13. |
| Find & Replace | `EdmundCore/Find/FindEngine.swift` (pure search), `TextView/EditorTextView+Find.swift` (match state, highlight drawing, pop animation, `EditorFindHandling`), `edmd/Views/FindBarView.swift` (the bar), `edmd/App/FindController.swift` (mediator); Edit ▸ Find menu in `main.swift` |
| Standard text menus | `edmd/App/main.swift` — Edit ▸ Spelling and Grammar, Transformations, Speech; stock `NSTextView` actions routed to the first responder. **Substitutions is deliberately excluded** (§8) |
| Status bar | `edmd/Views/StatusBarView.swift` |
| Build/packaging | `scripts/build-app.sh` (release build + Sparkle.framework embedding + signing), `Package.swift`, `Info.plist`, `Resources/` |

Notable subsystems:

- **A draw-only setting needs more than `invalidateLayout` to appear.** The
  layout manager hands back its *cached* fragments, so a paragraph vended as a
  plain `NSTextLayoutFragment` stays plain and the new overdraw never shows
  (measured: a live toggle drew nothing until the next edit). `refreshOverdraw()`
  also pokes the storage with an attributes-only `edited(.editedAttributes, …)`
  — no text change, no restyle, no undo entry — to force a re-vend. Invisibles,
  list indent guides and focus mode all depend on it; the affordances that use
  it are in
  [`architecture/editor-affordances.md`](architecture/editor-affordances.md).

- **Typewriter scroll**: keeps caret vertically centered. Must lay out the
  viewport↔caret span before measuring (else stale TK2 estimates);
  re-centers only on *typing* — a mouse-down sets
  `suppressTypewriterCentering` so click-placing the caret doesn't yank the
  viewport.
- **Content width** (`+ContentWidth.swift`): an **absolute physical**
  max-column width — set in cm/in in Settings, stored as cm, converted to
  points via the display's real PPI (`NSScreen.physicalPPI`, from
  `CGDisplayScreenSize`). Applied as a symmetric `textContainerInset.width`
  cap: wider windows center the column, narrower ones fill. Recomputed on
  resize and on moving to a differently-scaled display
  (`NSWindow.didChangeScreenNotification`).
- **Format menu & shortcuts**: pure AppKit (no SwiftUI scene, so SwiftUI
  `Commands` isn't an option). `FormatMenu.swift` is a declarative command
  table (`MenuCommand` + `Shortcut`, each with a stable `id` so a later pass
  can read per-command shortcut overrides from UserDefaults). Items use a
  nil target and route through the responder chain to the focused
  `EditorTextView`'s `@objc format…` actions — same wiring as undo/redo.
  Actions funnel through two primitives in `+FormattingCore.swift`:
  `applyFormattingEdit` (single contiguous edit, modeled on the Tab-indent
  path) and `applyWholeDocumentEdit` (non-contiguous, e.g. footnotes).
- **View modes**: ⌘E (View menu + toolbar button) *toggles* editing ↔ Read
  via `Document.toggleViewMode`. **Source is not a third toggle stop** —
  it's a persisted preference (`AppSettings.sourceMode`, a "Source Mode"
  checkbox in the View menu and the toolbar button's right-click menu):
  when on, the editing half of the toggle is Source instead of Edit, and a
  freshly opened document honors it. The toolbar button left-clicks to
  toggle, right-clicks for the full mode menu (§8: why that right-click is
  intercepted in `DocumentWindow.sendEvent`). Toolbar has
  `allowsUserCustomization = true` (an AppKit `NSToolbar` feature).
- **Read mode is a separate WKWebView**, not an editor styling mode.
  `.reading` swaps the editor's scroll view for a `ReadModeWebView`
  rendering themed HTML (`Export/`); Edit and Source stay on the
  `EditorTextView`. One parser, two back-ends (`SpanCollector` → editor
  attributes, `HTMLRenderer` → HTML), same `EditorTheme` via `HTMLTheme` —
  the two can't drift. Sandboxed: JS disabled, `script-src 'none'` CSP,
  `baseURL: nil`, every asset inlined as data URIs; remote images off by
  default (`ReadRenderOptions.allowRemoteImages`); external
  `http`/`https`/`mailto` links open in the browser, `file:`/unknown
  schemes cancelled; wikilinks/relative links use private
  `x-edmund-wiki:`/`x-edmund-link:` schemes the nav coordinator intercepts.
  **Inspect Reader (⌥⌘I)** is a semi-toggle on `Document`, not on the web
  view, so it works from Edit too: it switches to Read and opens WebKit's
  private `_inspector`, and closes it when already up; entering Edit always
  hides it. The read view's context menu carries the same item as "Inspect
  Element", with WebKit's own duplicate removed.
  **Export as PDF… / Print… (⌘P)** run the same HTML through
  `WKWebView.printOperation` (`MarkdownPrinter`; vector text, math is
  high-DPI PNG). Full spec: `docs/architecture/reader-and-export.md`.
- **Find & Replace** (in-document, ⌘F / ⌥⌘F / ⌘G / ⇧⌘G): **not**
  `NSTextFinder` — it renders the system bar rather than the Notes look, and
  its highlighting drives `NSLayoutManager`, which the TextKit 2 tripwire
  (§2) forbids. Instead: `FindEngine` is a pure `NSString.range(of:)` scan
  (case-sensitive / whole-word options, no regex) over `rawSource`; because
  of the identity invariant, search index == raw index == display index, so
  there is **no offset mapping**. Highlighting is **draw-only** — a
  `drawBackground(in:)` override fills rects from
  `enumerateTextSegments(in:type:.highlight)`, offset by
  `textContainerOrigin` — so it never writes attributes into storage and
  can't perturb recompose. Navigation never moves the caret (that would
  trigger the active-block-renders-raw recompose); it scrolls via
  `revealFindMatch`, which leaves an already-visible match alone and
  otherwise puts the hit's line at the top. Every match gets a grey resting
  background; the one just navigated to also gets a Preview-style "pop" — a
  drop-shadowed rounded yellow box that springs in from a larger scale with
  an `easeOutBack` overshoot, holds, then fades, driven by a `CADisplayLink`
  (constants at the top of `+Find.swift`). Replace / Replace All are the
  only paths that touch text and go through the sanctioned edit cycle (§4),
  Replace All rebuilding the source back-to-front so it lands as one undo
  step. EdmundCore stays unaware of the controller via the
  `EditorFindHandling` protocol — the same decoupling as
  `contextFontMenuProvider`. The bar itself is an `NSGridView` (2×2) so the
  two fields share a left edge and the `‹ ›` / `Replace|All` clusters share
  theirs; find-only is one row and toggling Replace reveals the second and
  moves **Done** down onto it, with a hairline along the bar's bottom edge
  (whichever row is last) matching the toolbar separator.
  **Keyboard model.** ⌘F and ⌥⌘F each *toggle their own* bar — the shortcut
  for the bar already showing closes it, the other switches to it, so ⌘F from
  the replace bar drops the replace row rather than closing outright:

  | from | ⌘F | ⌥⌘F |
  | --- | --- | --- |
  | closed | find | replace |
  | find | closed | replace |
  | replace | find | closed |

  Return / ⇧Return in the search field step to the next / previous match, as
  do ⌘G / ⇧⌘G. Tab walks the bar in visual order and wraps — including
  *inside* the segmented controls, so `‹`, `›`, `Replace` and `All` are each
  individually reachable — and ⇧Tab walks it in reverse. Both behaviours
  needed AppKit worked around; see §8.
- **Mode-switch viewport sync** (Edit ↔ Read, line-accurate both ways):
  read HTML blocks carry `id="edmund-l<startLine>"` anchors; scroll maps as
  (anchor line, fraction-into-block) via API-injected `evaluateJavaScript`
  (a trusted channel — content-JS-off and the CSP don't gate it); both
  directions share the same `lineCount` denominator so an untouched round
  trip is a fixed point; both swaps are deferred so no intermediate frame
  shows. Full spec: `docs/architecture/reader-and-export.md`. Two hard-won
  gotchas (§8): capture the anchor *before* the `viewMode` setter runs;
  far scrolls must style-then-lay-out everything above the target before
  measuring.

---

## 7. Settings & persistence

- `AppSettings` (`edmd/Settings`) = UserDefaults keys + typed accessors.
  SwiftUI panes use `@AppStorage`. Live changes broadcast to every open
  `Document.editor` (the font/line-height/content-width `applyTo…` helpers).
- **Five panes**, built by `SettingsWindowController.addPane`: General,
  Appearance, Edit, Syntax, Advanced. Keys are namespaced to match
  (`settings.<pane>.<name>`), so the key tells you which pane owns it. There is
  no "Markdown" pane — the Markdown feature toggles (§6) live under
  `settings.syntax.*`.
- This section owns the *mechanism* and the settings with non-obvious
  behavior, not the full key list — that inventory drifts fastest and lives in
  `.claude/skills/edmund-config-and-flags/`. Grep
  `Sources/edmd/Settings/AppSettings.swift` for the current truth.
- Theme/appearance/fonts flow into `EditorTheme` → the editor's derived
  `bodyFont`, colors, paragraph styles.
- **Max content width** persists as **centimetres** (`maxContentWidthCm`);
  cm/in is a display unit (`contentWidthUnit`), the column is always
  physical (§6). Default is locale-aware — 5 in (US) / 12 cm (elsewhere) —
  and is the slider's magnetic snap point; slider range: 3 in floor → the
  screen's physical width (`NSScreen.physicalWidthCm`).
- **Window size** persists as the last window's full **frame** size
  (`settings.window.lastWidth`/`lastHeight`) — §8 on why frame, not content
  size.
- **Diagnostic logging** (`EdmundCore/Diagnostics/Log.swift`): always-on
  (opt-out) file logger. `Log.{debug,info,error}(_:category:)` and
  `Log.measure(_:) { … }` (single-line durations) write to
  `~/.edmund/logs/edmund-YYYY-MM-DD.log` on a private serial queue. One
  compile-time level threshold (DEBUG = `debug`+; release = `info`+); the
  user only toggles on/off and picks retention (Settings ▸ General ▸
  Diagnostics). `AppSettings.applyLogging()` pushes toggle/retention into
  `Log.configure` at launch and on change; retention is pruned there.
- **Crash-log uploading** (`EdmundCore/Diagnostics/CrashReporter.swift`):
  opt-in (default off), fire-and-forget POST of `edmd-*.ips` files from
  `~/Library/Logs/DiagnosticReports/` not yet in
  `AppSettings.sentCrashReports` (dedup) to
  `CrashReporter.reportingEndpoint`. `edmd` is the Mach-O executable name —
  that's the crash-report filename prefix. **The Settings ▸ Advanced toggle
  is currently commented out** (the `// Crash reports:` GridRow in
  `AdvancedSettingsView.swift`); uncomment it and set a real
  `reportingEndpoint` once the receiving server exists. Reading
  DiagnosticReports directly only works un-sandboxed; under App Sandbox
  switch to MetricKit's `MXCrashDiagnostic`.

---

## 8. Quirks & gotchas (will bite you)

### Build, signing & packaging

- **A green local `swift test` does not mean CI compiles.** The local CLI runs
  a swift.org toolchain (`TOOLCHAINS` in `~/.zshrc` — 6.3.3); CI is macos-14 +
  `latest-stable` Xcode (6.0.3). Concurrency *inference* differs between them:
  SwiftUI's `View` is `@MainActor @preconcurrency`, so on 6.0.3 a `static func`
  on a `View` is inferred main-actor-isolated and a synchronous test suite
  cannot call it — an error 6.3.3 never emits (cost PR #249 a red `test` run).
  Mark such helpers `nonisolated`. Before pushing anything that touches
  isolation or a SwiftUI type's members, check parity:
  `env -u TOOLCHAINS xcrun swift test --build-path .build-xcode`
  (separate build path so it can't poison the normal `.build`; delete it after —
  it is not gitignored).
- **SwiftMath fonts**: `build-app.sh` must copy `*.bundle` into the `.app`
  root (it does). Without it the app **crashes the instant it renders any
  LaTeX**.
- **Sparkle codesign — must seal the whole bundle**: Sparkle re-validates
  the downloaded update's Apple code signature (`SUUpdateValidator`); a
  bundle that reports as signed but fails `SecStaticCodeCheckValidity` is
  rejected as *"The update is improperly signed…"*. The old script signed
  only the main binary (no `_CodeSignature/CodeResources`) — **every
  Sparkle update failed** (the v0.1.0→0.1.1 error). Fix: `build-app.sh`
  seals the whole `.app` (`codesign --deep`) while the root holds only
  `Contents/`, then copies the SwiftMath bundle in **after** signing (it
  must sit at the `.app` root — its generated `Bundle.module` accessor is
  hardcoded to `Bundle.main.bundleURL` — and codesign refuses to seal with
  any item at the root). That one unsealed root item makes
  `codesign --verify` (CLI) and `--strict` complain, but Sparkle's actual
  check (`SecStaticCodeCheckValidityWithErrors` +
  `kSecCSCheckAllArchitectures`, non-strict) tolerates it — verified
  against that exact API. Developer ID + notarization would be cleaner;
  ad-hoc is the current limit.
- **Sparkle keypair**: public key in `Info.plist` `SUPublicEDKey`, private
  key in the login keychain **and** the CI secret `SPARKLE_ED_PRIVATE_KEY`.
  Don't let them diverge. Details: §13.
- **`create-dmg` — npm only, three quirks**: install via **npm**
  (`npm install --global create-dmg`), not Homebrew — different tools,
  incompatible CLIs; needs Node ≥20. Exits **2** (not 0) when it can't
  Developer-ID-sign (we ship ad-hoc) but still produces the `.dmg` —
  `release.sh` and CI use `|| true` then verify the file exists. Names the
  output `"Edmund <version>.dmg"` (space); both scripts rename to
  `Edmund-<version>.dmg` before signing/uploading.
- **Stale builds**: `swift build` (debug *and* release) can print `Build
  complete!` after compiling a changed file **without relinking `edmd`** —
  you run old code. Detect: grep
  `strings .build/arm64-apple-macosx/debug/edmd` for a long string literal
  unique to the new code (literals ≤15 bytes are stored inline on arm64 and
  never appear). Cure: `swift package clean`; if a visual change "doesn't
  take", `rm -rf .build` and rebuild. `shasum` the binary to confirm it
  changed. Never hand-delete `.build/…/edmd.build/` — corrupts the
  output-file-map and wedges the target until a full clean.

### Running & verifying the app

- **`open Edmund.app` foregrounds a running instance** instead of
  relaunching. `pkill -x edmd` first, or launch the binary directly
  (`build/Edmund.app/Contents/MacOS/edmd file.md &`).
- **Screencapture for visual verification**: capture by window id (reliable
  even if not frontmost): `CGWindowListCopyWindowInfo` → find by
  `kCGWindowName` → `screencapture -x -o -l<id> out.png`. Crop by detected
  window bounds (the wallpaper defeats brightness-based auto-crop). After
  many rapid launch/kill cycles window-server state can glitch (tiny
  windows, state restoration) —
  `rm -rf ~/Library/"Saved Application State"/com.i7t5.edmund.savedState`
  and relaunch.
- **Visual work is measured, not eyeballed — and the measuring rig is
  reusable.** Aligning chrome takes a dozen launch/state/capture/measure cycles;
  `.claude/skills/edmund-live-repro-and-diagnostics/scripts/ui-harness.sh` and
  `ui-measure.py` are that loop, already encoding the flaky bits (AX-driven
  clicks, appearance forced per-launch via `-settings.appearance.mode`, capture
  by window id without stealing focus). Extend them for new surfaces rather than
  rebuilding one-off shell; they are permanent fixtures, not scratch files.
- **Don't drive the Settings window with System Events** to capture a pane.
  `click at {x, y}` is a no-op, the toolbar's pane items are intermittently
  absent from the AX element list, and the window frequently opens
  off-screen — where `CGWindowListCopyWindowInfo(.optionOnScreenOnly)`
  can't see it and `screencapture -R` grabs whatever else occupies that
  rect (another agent's window, in a parallel-worktree session). Instead
  add a temporary `showSettings(nil)` + `selectedTabViewItemIndex = N` in
  `applicationDidFinishLaunching`, build, capture by window id, then revert.
  Deterministic and needs no accessibility at all. Note
  `kCGWindowOwnerPID` bridges to `Int`, not `Int32` — the wrong cast
  silently matches nothing.

### TextKit 2 layout & geometry

- **Width not known at first styling**: on load the view may be unsized, so
  anything that bakes the content width (e.g. callout header images)
  renders at a fallback width until a width-settled re-render. Prefer real
  wrapping text over width-baked images.
- **Attribute-only changes don't re-measure geometry in TK2**: after
  restyling a block whose height/indent changed, `invalidateLayout(for:)`
  its range or the fragment keeps a stale frame (empty bands / clipped
  lines). `recomposeDirty` and the idle drain do this; new paths must too.
- **TK2 height *estimates* are the root of most viewport glitches.** A
  fragment has a real frame only once laid out; everything else (and total
  document height) is an estimate corrected as layout reaches it — that's
  the scroller jumping and scroll-to-target landing wrong (a documented TK2
  limitation; even TextEdit shows it). Mitigations: docs ≤
  `fullLayoutMaxLength` (100k UTF-16) are kept **fully laid out** by a
  coalesced next-run-loop settle (`scheduleFullLayoutSettle`, wrapped in
  `preservingViewportAnchor` so corrections never shift what's on screen);
  `centerViewportOnCaret` re-measures after its first scroll and corrects
  the residual; undo/redo avoids resetting layout at all (§4). Never trust
  an off-screen fragment's y-coordinate without laying out the span first.
- **TK2 can strand content above the document origin.** Edits near the top
  of a tall document can leave the first fragment at negative y — first
  line unreachable, scroller already at top. `repairContentAboveOrigin`
  (run by the layout settle) detects a negative first-fragment origin and
  re-lays start→viewport inside `preservingViewportAnchor`.
- **A selection taller than the viewport must be revealed at its *nearest*
  end** (`scrollRangeToVisible` override): always revealing the top fought
  drag-selection autoscroll and oscillated the viewport mid-drag.
- **A bitmap overlay must land on the device grid or it gets resampled** —
  and a resampled bitmap reads as *bolder*, not blurrier, because the same
  ink spreads over more pixels. Both halves matter: the destination size
  must be a whole number of device pixels (an `NSImage`'s point size is
  rounded independently of its pixel count, so `image.size` usually is
  *not*), and the origin must be a whole device pixel (a text baseline, or
  a centered x, never is). `mathOverlay` snaps the size; `deviceAligned`
  (EditorTextView+TextKit2) snaps the origin in *device* space, since a
  scrolled clip view can leave the CTM's translation on a fraction of a
  point. Measured on RaTeX equations before the fix: +32–38% inked device
  pixels at the same total ink, with solid-coverage pixels collapsing
  (173 → 31). Read mode pins its `<img>` to the PNG's exact pixel count for
  the same reason (`DocumentHTML.fillMath`).

### Edit, selection & storage integrity

- **Never mutate storage while an IME is composing (`hasMarkedText()`)**:
  during composition storage holds the provisional marked text, so
  `storage == rawSource` is transiently false and `didChangeText` defers
  syncing until commit. Styling that runs
  `beginEditing`/`setAttributes`/`invalidateLayout` mid-composition can
  strand the marked text in the input context — `didChangeText` then keeps
  bailing on its own guard and every later edit drifts the caret (the old
  "delete-drift" bug). Every storage-touching styling path must guard
  `!hasMarkedText()` — including async ones scheduled *before* composition
  began (`+SelectionTracking`'s caret-move restyle). `becomeFirstResponder`
  resyncs from storage as a catch-all. Full write-up:
  `docs/investigations/delete-drift-investigation.md`.
- **AppKit does not pair every storage mutation with `didChangeText`.** A
  drag-move whose drop lands on no valid target (e.g. released past the end
  of the document) deletes the dragged range via `shouldChangeText` →
  `replaceCharacters` and **never calls `didChangeText`** — silently
  freezing `rawSource`/`blocks`; every edit then drifts the caret and
  autosave writes the stale `rawSource` (delete-drift round 4).
  `shouldChangeText` therefore schedules a next-run-loop bypass check: a
  storage `pendingEdit` still unconsumed means the closing `didChangeText`
  never came, and the editor heals by running the same sync (`+EditFlow`,
  `scheduleBypassedEditSyncCheck`; breadcrumb in `~/.edmund/logs`: `healing
  storage edit that bypassed didChangeText`). Never build a sync path on
  the assumption that `didChangeText` follows every edit.
- **A bypassed edit also leaves TK2's selection fixup queued** (delete-drift
  round 6). The skipped
  `-[NSTextLayoutManager _fixSelectionAfterChangeInCharacterRange:]` fires
  at the **next** `endEditing` — even an attribute-only restyle — mapping
  the stale selection against post-edit coordinates and leaping the caret
  blocks away. It moves even a freshly set, valid caret, so the heal must
  set the caret (derived from the pendingEdit hull) *before* the sync **and
  re-assert it after** (`+EditFlow`). Suspicious selection changes arrive
  mid-recompose (`up=Y` in traces); under verbose diagnostics
  `traceSelectionOrigin` logs the mover's call stack — start there. This
  class does not reproduce headless (the test harness runs the fixup
  synchronously): DEBUG builds accept `-debug.reproScript <path>`
  (`Sources/edmd/App/ReproScript.swift`) — in-process keystroke replay
  (`caret` / `type` / `backspace` / `bypassdelete` / `assertcaret` /
  `logsel` / `scroll` / `viewmode` / `readscroll` / `logstate`) through the
  real `window.sendEvent` key path — no Accessibility/TCC needed, works on
  an invisible Space. Pass `-debug.disableUpdater YES` alongside —
  Sparkle's failed-update alert on dev builds is **modal at launch** and
  blocks everything until dismissed. Chronicle:
  `docs/investigations/delete-drift-investigation.md` round 6; method:
  `docs/dev-guides/live-repro-guide.md`.
- **The `viewMode` setter recomposes every block, collapsing far geometry
  to estimates** (~17pt/line base vs ~27pt styled) — `recomposeDirty` on a
  large dirty set defers non-viewport styling to the idle drain. Two
  consequences (the read-mode viewport-drift bug): capture any viewport
  anchor **before** `editor.viewMode = mode` runs (`Document.setViewMode`
  does), and a far `scrollCharacterToTop` must style-then-lay-out
  everything above its target before measuring
  (`ensureBlocksStyled(upTo:)` + `ensureLayout`) — the drain's later layout
  invalidation is *not* scroll-compensated, so landing first and letting
  styling catch up slides the just-anchored viewport.

### AppKit chrome & controls

- **A custom toolbar item can't win a right-click from a view-level
  handler.** With `allowsUserCustomization = true` the toolbar turns any
  secondary (right / control) click over the toolbar — *including* a custom
  item view — into its "Customize Toolbar…" context menu. The view's
  `menu`, a `rightMouseDown` override, and a secondary-button
  `NSClickGestureRecognizer` **all lose**. Fix (view-mode button):
  intercept in `DocumentWindow.sendEvent(_:)` — the documented funnel every
  window event passes through *before* the toolbar acts — and when the
  click falls inside the button's bounds, pop the menu and swallow the
  event. (Caveat: true fullscreen moves the toolbar to a separate window
  this main-window hook doesn't cover.)
- **Window-size persistence must round-trip the frame, not the content
  size.** Saving `contentView.bounds.size` and re-applying it as the
  initializer's `contentRect` grows the window by title-bar + (unified)
  toolbar height every reopen — and content heights below the frame
  `minSize` get silently rejected. Save `window.frame.size`, re-apply with
  `window.setFrame(_:)` **after the toolbar is installed** (the frame is
  only final then), so frame-in == frame-out (`windowDidResize` ↔
  `makeWindowControllers` in `Document.swift`).
- **A frame-managed subview parked at the zero frame sets the window's
  minimum width.** The find bar resizes by `autoresizingMask`, but its
  contents are Auto Layout, so its required constraints reach the window as
  a `contentMinSize`. A flexible-width autoresizing view only grows by the
  *delta* from the width it was added at — so a bar added at `.zero` first
  reaches the width its fields and buttons need when the window is that much
  wider than it opened. AppKit reads the minimum as `initial width + bar
  minimum` and inflates the opening frame to satisfy it: the 800pt default
  opened at 1014 and would not shrink below it, `window.minSize` was
  inert (dropping it to 320 moved neither number), and the initial size and
  the minimum moved together. Fix: size the bar to the container when
  parking it (`FindController.init`). Note this is invisible to headless
  tests — only the live window server applies `contentMinSize`, so verify by
  launching and asking AX to resize the window smaller than it can go.
- **`NSSearchField`'s magnifier glyph can't be repositioned — draw your
  own.** AppKit draws it ~3.75pt below the field's vertical centre (a 21×15
  image in a rect the field's full 22pt height). Every built-in hook is a
  dead end, and each was measured, not assumed:
  `searchButtonRect(forBounds:)` is only a *sizing probe* (AppKit calls it
  with a 40000×40000 bounds, never to position); the button cell's
  `drawInterior(withFrame:in:)` is bypassed by the search field's private
  draw path; the cell ignores a replacement image entirely (the Big Sur
  regression, FB8913004), so re-padding the image does nothing; and the
  glyph is not a subview, so there is nothing to move in `layout()`.
  `imageRect(forBounds:)` *is* honoured, but drawing is clipped to a fixed
  band, so shifting or growing the rect just chops the top off the glyph.
  What works (`FindBarView.swift`): swap in a button cell whose
  `imageRect` returns `.zero` — it draws nothing but still handles the
  click, so the search-options menu keeps working — and draw the
  magnifier + ▾ yourself in the field's `draw(_:)`, centred on
  `searchButtonRect(forBounds: bounds)` (that call *is* correct for real
  bounds). Template images drawn by hand render flat black, so tint per
  draw or the glyph won't follow light/dark.
- **Place a hand-drawn SF Symbol by its *ink*, not its image bounds.** Symbol
  images carry internal padding that varies per symbol, so drawing one at its
  image rect lands it a couple of points off whatever you measured. Render the
  symbol once, scan its alpha for a tight bounding box, then scale/offset so the
  *ink* hits the measured target (`CountingSearchField.inkBounds`). Two traps:
  `NSBitmapImageRep.size` must be assigned **before** the `NSGraphicsContext` is
  made — it defines the context's coordinate space, and a late assignment
  measures at the wrong scale; and a text field's coordinate space is **flipped**,
  so a positive y offset moves a glyph *down*. Both were found by sweeping the
  constant and measuring, which is the only way to settle a sign question here.
- **A first-responder menu command dies wherever the target isn't in the
  responder chain.** The Edit ▸ Find items route to `EditorTextView`, so with
  focus inside the find bar the editor is *not* in the chain — the bar is —
  and ⌘F / ⌥⌘F / ⌘G / ⇧⌘G greyed out exactly while you were typing a query.
  Fix: implement the same selectors on the focused view too (`FindBarView`
  forwards them). Applies to any overlay that takes focus.
- **AppKit rebuilds the window's key-view loop and wipes your `nextKeyView`.**
  A hand-built Tab chain silently reverts whenever the view tree changes;
  `window.autorecalculatesKeyViewLoop = false` is what makes it stick. Views
  that can't become key views are skipped automatically, so declaring the
  whole chain (buttons included) is safe — but buttons only join when macOS
  *Keyboard navigation* is on, which nothing in-app can override.
- **Tab never enters an `NSSegmentedControl`.** AppKit focuses segments
  individually — the focus ring sits on one segment and ← / → move it — but
  Tab always leaves the whole control, so a trailing segment (`›`, `All`) is
  unreachable by Tab alone. `SegmentTabbingControl` translates Tab into that
  arrow handling until the last segment, then releases it to the key-view
  loop. The focused index has no public accessor, so it's mirrored, and the
  mirror must be seeded by *entry direction* — AppKit enters on the leading
  segment forwards and the trailing one via ⇧Tab.
- **`NSVisualEffectView` ignores `draw(_:)`.** It renders its material through
  layers and never calls a custom draw, so a border painted there is simply
  invisible (measured: nothing appeared). Use a pinned subview with a layer
  background, and refresh its `cgColor` on
  `viewDidChangeEffectiveAppearance` — a colour snapshot won't follow the
  appearance by itself.

### Deliberate omissions

- **Edit ▸ Substitutions is deliberately absent.** Smart quotes/dashes, text
  replacement and autocorrect are switched off in
  `EditorTextView.commonInit()` on purpose: they rewrite typed Markdown, and
  the completion machinery can strand marked text and break
  storage == rawSource (delete-drift investigation). Don't add the standard
  Substitutions menu back — it re-exposes exactly those toggles. Same reason
  "Correct Spelling Automatically" is left out of Spelling and Grammar.

- **Edit-mode math looks "heavier" than read-mode math because it *is* a
  different color, not a rendering defect.** Edit mode colors math (and all
  text) with `.textColor` (pure black in light appearance); read mode uses
  the softer `#1a1a1a`/`#e6e6e6` `--fg` palette for everything. Both are
  working as designed — math just matches its ambient text color in each
  mode. See `docs/investigations/math-ratex-weight-investigation.md`.
- **A `//` line comment inside `HTMLTheme.swift`'s CSS string literal is
  invalid CSS and silently drops the whole rule** (CSS has no `//` syntax;
  the parser chokes past it until the next `{`). Use `/* */`. Cost a whole
  round of "why doesn't this CSS change do anything" — see
  `docs/investigations/math-ratex-weight-investigation.md` Round 1.

---

## 9. Known issues / lurking problems

- **Images can't be drawn on multi-line (wrapping) fragments** (TK2 image
  wedge — collapses the fragment's layout to one line). Resolved for the
  callout custom-title icon via stroked `CGPath` (shapes don't wedge); the
  constraint still holds for any *new* overlay that could share a line with
  wrapping text. Full investigation:
  `docs/investigations/archives/callout-title-wrap-investigation.md`.
- **RaTeX rendered inline math in display style until 0.1.14**, because
  `renderLatex`'s `displayMode` argument didn't exist yet and the engine
  defaults to display — so `$\sum_{i=1}^{n}$` stacked its limits above and
  below mid-sentence. Fixed by passing the argument explicitly
  (`WasmMathHost.render`). Prefixing `\displaystyle` was never the lever it
  appeared to be: with the default already display, it measured identically
  with and without.
- **The recorded "RaTeX `aligned` row-spacing" defect did not survive
  re-testing and is not a known bug.** It was filed against 0.1.12 by
  comparing two *different* equations rather than one equation across two
  versions. Head-to-head on identical input, 0.1.12 and 0.1.14 both stack
  multi-row `aligned` correctly (four `\lim`/`\frac` rows: 4 clean
  y-clusters, ~10em total, both versions). Nothing upstream was ever waiting
  to be fixed here. If multi-row math ever collapses again, the escaping
  round-trip is the thing to suspect first, not RaTeX's layout — see the next
  entry. Full write-up: `docs/investigations/math-ratex-multirow-investigation.md`.
- **swift-markdown unescapes `\\` before you ever see the LaTeX.** A `Text`
  node's `.string` has Markdown backslash-unescaping applied (`\\`→`\`,
  `\$`→`$`), which silently turns an `aligned` block's row separators into
  nothing — every row lands on one line. Read mode therefore parses math from
  the *raw* source (`sourceText(paragraph)` in `HTMLRenderer.visitParagraph`),
  exactly as edit mode reads by range. The `?? Self.plainText(of:)` fallback
  on that line is the mangled path — anything that makes `sourceText` return
  nil reintroduces the collapse.
- *(Add new ones here as you find them — with a one-line repro and a
  pointer to any deeper write-up in `docs/`.)*

## 10. Still to address

- **Raw HTML: Read renders it per GFM; Edit shows colored source** — the
  GitHub split (rendered HTML in Edit is impossible under
  storage==rawSource). Read filters via `HTMLRenderer.filterRawHTML` = GFM
  tagfilter **plus** hardening (`on*` attributes stripped,
  `javascript:`/`vbscript:` neutralized), behind the webview sandbox (JS
  off, `script-src 'none'` CSP, `baseURL: nil`); a raw `<img>` is rewritten
  to the `md-image` placeholder (`DocumentHTML.fillImages` — the
  remote-image-policy chokepoint). Edit renders `.htmlBlock` blocks and
  inline tags as colored source; the `htmlFormatTags` whitelist is
  *presentation*, not sanitization. Spec divergences + full policy:
  `docs/architecture/reader-and-export.md`. Still deferred in Edit mode:
  reference links/definitions, blockquote lazy continuation,
  entity-reference styling, the 2-trailing-space hard-break span.
- **Edit-mode table alignment** distributes each cell's slack via `.kern`,
  putting the right/center "before" pad on the cell's *hidden* leading pipe
  (kern still adds advance on a 0.01pt glyph) —
  `EditorTextView+TableRendering.swift`. Column widths are clamped to the
  available line width (`distributeColumnWidths`,
  `EditorTextView+TableSupport.swift`) so one very wide cell can't stretch
  the table off screen; a cell whose styled width still exceeds its clamped
  column hides its real characters and is redrawn wrapped via a
  `.tableCellWraps` attribute (`EditorTextView+TextKit2.swift`), resolved
  through a detached scratch `NSTextContentStorage`/`NSTextLayoutManager`
  sized to the column's content width — the same "hide the real chars, draw
  the visual yourself" pattern as `.fragmentOverlay`, needed because TK2
  only wraps a whole paragraph at the container edge and has no per-cell
  flow region (that's NSTextTable/NSTextBlock, banned per §2).
  Such a cell still kerns out its full column: its hidden characters
  advance ~nothing, so without that pad every cell after it in the row slid
  left onto its neighbour (#251). Its drawn lines carry the column's
  alignment individually, and a click inside one is resolved against the
  scratch layout (`cellWrapCharacterIndex`, used from `mouseDown`) rather
  than the hidden characters — all of which sit at one x, so AppKit's own
  hit-testing would answer the same character everywhere in the cell. Two
  geometry traps: the fragment's draw point is the row's *text* start
  (already indented by the cell pad, like `.tableRow`'s `leftInset`), and a
  row's own line box starts below its `paragraphSpacingBefore` — a wrapped
  cell has to match both or it draws a pad right of, and a hair above, the
  in-line cells beside it. Column widths also leave the row a little slack
  at the container edge, or a right-aligned column's glyphs reach the edge
  and force-wrap the row. Interior data rows draw a full-width bottom grid line (`.tableRow`'s
  `bottomBorder`) — the header/body boundary already gets its line from
  `separator`, and the last row draws none, so the table's bottom edge is open
  like its left and right edges.
- *(Track larger roadmap items in README/ROADMAP; track code-debt here.)*

---

## 11. Quick start for an agent

1. Skim README (what/why), then this doc (how).
2. `swift build && swift test` — confirm green before changing anything.
3. Find the feature's `Rendering/` or `TextView/` extension via §6.
4. Make the change; add/adjust tests in `Tests/EdmundTests` (helpers:
   `makeEditor()`, `ensureFullLayout()`, `styleBlock()`).
5. Verify per §12 before committing.

Debugging a live-only bug (caret, IME, drag, viewport timing)? Follow
`docs/dev-guides/live-repro-guide.md` — trace-reading first, then the
in-process ReproScript driver; don't burn time on headless attempts for
that class.

---

## 12. Working agreements (pre-commit checklist)

Do these **before every commit** (this is the workflow that worked; deviate
only with reason):

1. **`swift test` is green** (all pass). Add tests for new behavior / bug
   repros.
2. **Visual changes are measured, not eyeballed** — build the app and
   `screencapture` the result (§8), or render offscreen to a PNG. Don't trust
   headless layout alone for anything that draws. For anything phrased as
   *align / centre / balance the padding / match the native control*, report
   **numbers** (device px and points, 2:1 on Retina), not an impression —
   "the glyph's centre is 137.5, the field's is 137.5" settles what "looks
   right" cannot. Drive the app with the reusable harness rather than fresh
   one-off shell: `ui-harness.sh` + `ui-measure.py` in
   `.claude/skills/edmund-live-repro-and-diagnostics/scripts/`. **Keep and
   extend those tools** — they're checked-in fixtures, and the setup cost is
   otherwise paid again every visual task. `ui-measure.py weight` compares
   stroke weight/sharpness between two captures (ink, spread, solidity) —
   that's how the math-overlay resample was proven. No python here has
   numpy/Pillow; run it as
   `uv run --with numpy --with pillow ui-measure.py …`.
3. **Frequent, small, logical commits** — one feature/fix each. Don't
   discard uncommited changes.
4. **Don't autopush, PR, or merge unless asked.** Branch off `main` (don't
   commit straight to it); each fix on its own branch.
5. Touch only what the task needs; match surrounding style; don't refactor
   unrelated code.
6. **Concurrent local work uses `git worktree`, not multiple clones or
   branch-switching.** `git worktree add .worktrees/<branch> <branch>` —
   the directory path mirrors the branch name (e.g. `.worktrees/fix/foo`
   for `fix/foo`), so branches keep the normal `type/slug` naming and never
   get renamed to `worktree-*`. `.worktrees/` is gitignored. Distinct from
   `.claude/worktrees/`, which Claude Code's own EnterWorktree tool manages
   automatically for agent isolation — don't hand-edit that one.
7. **Reviewing someone else's PR uses `/edmund-pr-review <number>`**
   (`.claude/skills/edmund-pr-review/`). It gathers the PR, checks it against
   the invariants and the TextKit 2 estimate rule, verifies the claim the merge
   rests on instead of relaying it, asks the maintainer for the calls that are
   theirs, and emits a merge checklist. Shipping your *own* change is `/ship`
   (`.claude/commands/ship.md`) — different job.

If you (the agent) improve this workflow or discover a better verification
trick, update this section.

---

## 13. Release & CI pipeline

How a release happens, plus the non-obvious things that broke shipping 0.1.0.

**Flow (tag-triggered).** Push a `vX.Y.Z` tag →
`.github/workflows/release.yml` (`macos-14`): build the `.app`
(`build-app.sh`) → DMG (npm `create-dmg`) → EdDSA-sign the DMG →
`gh release create` (notes = the matching `CHANGELOG.md` section, extracted
by `awk`) → commit the new `<item>` into `appcast.xml` on `main`.
`scripts/release.sh` mirrors this locally but leaves the appcast
commit/push to you. The `<item>` also gets a `<description>` (HTML release
notes from the CHANGELOG section via `scripts/changelog-to-html.py`) so
Sparkle's update dialog shows the changelog.

**To cut a release:** bump `CFBundleShortVersionString` / `CFBundleVersion`
in `Info.plist`, add a `## [x.y.z]` section to `CHANGELOG.md`, merge to
`main`, then `git tag vx.y.z && git push origin vx.y.z`.

**EdDSA keypair — set up, not a placeholder.** Public key in `Info.plist`
`SUPublicEDKey` (`0XdLbbuO…`); the private key lives in two places that
must stay the *same* keypair: the maintainer's **login keychain** (used by
`release.sh`, no flag) and the Actions secret **`SPARKLE_ED_PRIVATE_KEY`**
(CI). Verified end-to-end: a CI-signed DMG verifies against the
`Info.plist` public key (`sign_update --verify <dmg> <sig>`). If they
diverge, the DMG signs fine but every user's update fails verification.

**`sign_update -s` is fatal for newly generated keys** — deprecated; for
keys generated after that change it prints a warning and **exits 1**. This
killed the first 0.1.0 release. Feed the key on **stdin** instead (both
`release.yml` and `release.sh` do):
`echo "$SPARKLE_ED_PRIVATE_KEY" | sign_update --ed-key-file - <dmg>`.

**Appcast push to protected `main` needs an admin PAT.** `main` requires
the `test` status check; the default `GITHUB_TOKEN` /
`github-actions[bot]` push is rejected (`GH006 … protected branch hook
declined`). `main` protection has `enforce_admins: false`, so an admin's
push bypasses the check — `release.yml`'s **checkout step** authenticates
with a fine-grained admin PAT in the **`RELEASE_TOKEN`** secret (Contents:
read/write). Set it on *checkout*, not by rewriting the push URL:
`actions/checkout` persists an `http.<host>.extraheader` credential that
otherwise overrides inline-URL creds. **`RELEASE_TOKEN` expires
2027-06-27** — rotate before then or releases fail at the appcast push.

**Gatekeeper / notarization.** Ad-hoc signed, not notarized: users hit
Gatekeeper on first launch; the README documents the
`xattr -dr com.apple.quarantine` / right-click-Open workarounds. Developer
ID + notarization (§8) would remove the prompt entirely.

**Never release anything through this pipeline except the main app.** The
tag flow builds and ships `Edmund.app` only. Extension payloads (e.g. the
RaTeX WASM) have their own hosting/release path — never bundled into or
triggered by an Edmund version tag. (The RaTeX WASM asset was pulled from
release pending `erweixin/RaTeX` inline-mode support and the Advanced Math
extension's repo migration — see `misc/backlog.md`.)

---

## 14. References

Dependencies and prior art worth consulting before designing something new:

- [apple/swift-markdown](https://github.com/apple/swift-markdown) — the
  CommonMark/GFM parser both back-ends walk (§3, §6).
- [SwiftMath](https://github.com/mgriebling/SwiftMath) — LaTeX rendering
  (raster only; no SVG output yet — why exported math is PNG, §6).
- [Sparkle](https://sparkle-project.org) — auto-update (§8, §13 for the
  signing/appcast quirks).
- [Lucide](https://lucide.dev) — vendored icon SVGs (ISC),
  `Model/LucideIcons.swift`.
- [nodes-app/swift-markdown-engine](https://github.com/nodes-app/swift-markdown-engine)
  — an independent AppKit + TextKit 2 live-preview markdown engine (Apache
  2.0, macOS 14+). Solves the same problems with different trade-offs —
  useful comparison before inventing a new mechanism for an
  editing-experience problem, and a candidate source of techniques (e.g.
  drag-select autoscroll, overscroll).
