# Edmund — architecture & agent onboarding

A native macOS Markdown editor with live preview (AppKit + TextKit 2, SPM,
macOS 14+). This doc gets an AI agent productive fast: read it before any
non-trivial change. **Keep it updated** — when you learn something non-obvious
or change an invariant, edit this file in the same PR.

---

## 1. Build / run / test

```bash
swift build                 # debug build of both targets
swift test                  # full suite (≈630+ tests, ~10s)
swift test --filter Callout # one suite
./scripts/build-app.sh      # builds build/Edmund.app (release + bundles + icon + codesign)
```

Run the app for visual checks (see §8 for the gotchas):
```bash
pkill -x edmd; build/Edmund.app/Contents/MacOS/edmd /path/to/file.md &
```

Two SPM targets (see `Package.swift`):
- **`EdmundCore`** — the library: all editor logic, parsing, rendering, the
  `EditorTextView`. Has the tests. **Most work happens here.**
- **`edmd`** — the executable: `NSDocument` app shell, Settings (SwiftUI),
  menus, window setup. Depends on EdmundCore.

Dependencies: `swift-markdown` (CommonMark/GFM parsing), `SwiftMath` (LaTeX), and `Sparkle` (auto-update).

---

## 2. The two non-negotiable invariants

Break either and the whole editor misbehaves in subtle ways.

1. **Text storage always equals `rawSource`.** Rendering is *attribute-only* —
   we never insert/delete display characters. Delimiters (`**`, `` ` ``,
   `[!note]`, etc.) are *hidden* (near-zero font + clear color), never stripped.
   Consequences: no `NSTextAttachment` (TextKit 2 only honors them on U+FFFC,
   which `rawSource` never contains — so images/icons are drawn as overlays
   instead, see §5); display offset == raw offset (identity mapping).

2. **TextKit 2 only.** Never touch `NSTextView.layoutManager` and never store
   `NSTextBlock`/`NSTextTable` attributes — either silently reverts the view to
   TextKit 1 for good. A DEBUG tripwire asserts if TK1 is engaged. Layout is
   viewport-based (only on-screen content is laid out), which is what makes big
   documents fast.

---

## 3. Rendering pipeline (the core loop)

```
rawSource ──BlockParser──▶ [Block]  ──styleBlock per block──▶ attributed runs
                                          │
                                          ├─ SyntaxHighlighter (swift-markdown
                                          │   Walker + custom parsers for
                                          │   callouts, ==highlight==, wikilinks,
                                          │   comments, footnotes, math)
                                          └─ writes attributes into textStorage
```

- **`BlockParser`** (`Parsing/`) splits `rawSource` into `Block`s (one per
  logical block: paragraph, heading, list run, quote/callout run, code fence,
  table…). `Block.kind` is a `BlockKind` enum (e.g. `.quoteRun(isCallout:)`).
- **`SyntaxHighlighter`** + `+Walker`/`+WalkerInline`/`+CustomParsers` produce
  styling spans. The custom parsers handle the non-CommonMark syntax.
- **`styleBlock(_:cursorPosition:)`** (`Rendering/EditorTextView+Rendering.swift`)
  renders ONE block to an attributed string. Each feature has a `Rendering/`
  extension: Callout, Code, Image, List, ListMarker, Math, Table, WikiLinks.
- **Recompose** (`TextView/EditorTextView+Composition.swift`) drives styling:
  - `recompose(cursorInRaw:)` — full: replaces storage with rawSource, restyles
    all blocks (load, undo, indent).
  - `recomposeDirty(_:cursorInRaw:)` — restyles a specific set of block indices
    in place (the workhorse; attribute-only).
  - `recomposeIncremental(...)` — restyles just the block(s) the cursor moved
    between (most cursor moves).
  - **Active block**: the block under the caret renders its *raw* markdown
    (delimiters visible/editable); all others render styled. This is the "live
    preview reveals the active line" behavior.

- **Lazy styling** (`TextView/EditorTextView+LazyStyling.swift`): a large dirty
  set styles only the viewport synchronously; the rest is finished by the
  **idle drain** (time-budgeted main-thread slices) and **scroll promotion**
  (style blocks as they enter the viewport). Keeps large docs responsive.

---

## 4. Edit flow & undo

- Edits go through NSTextView's normal path: `shouldChangeText` records a
  coalesced undo snapshot → NSTextView mutates storage → `didChangeText` syncs
  `rawSource` and restyles the edited block(s) (`+EditFlow`, `+Composition`).
- **Incremental parsing**: edits capture a pending edit on `EditorTextStorage`
  and reparse a window, not the whole doc.
- **Undo/redo** is custom: stacks of `rawSource` snapshots (`+Undo.swift`),
  bypassing NSTextView's built-in undo. Restoring a snapshot manages the
  viewport deliberately (hold if on-screen, else center on the caret).
- **Cursor tracking** (`+SelectionTracking`): moving between blocks restyles
  both; moving within a block updates which token's delimiters are revealed.

---

## 5. TextKit 2 specifics (how visuals are drawn)

- **`DecoratedTextLayoutFragment`** (custom `NSTextLayoutFragment`, in
  `+TextKit2.swift`) draws two kinds of custom attributes behind/over the text:
  - **`.blockDecoration`** (paragraph-level): callout boxes, quote bars, table
    borders, thematic-break rules, code-block backgrounds. Fragments tile
    vertically, so a multi-line run renders as one continuous box/bar. A box's
    `bottomPad` grows the *last* fragment's frame (TextKit 2 omits trailing
    paragraph spacing from the fragment, so padding done that way would be dead
    space).
  - **`.fragmentOverlay`** (character-level): an image drawn at a character's
    laid-out position — rendered math, list bullets/checkboxes, the callout
    header icon+name image. The anchor glyph is hidden and `.kern` reserves the
    image's advance width (the same trick the table renderer uses).
- **Hiding** text = `hiddenFont` (≈0.01pt) + clear `foregroundColor`. This is
  how delimiters and synthesized-but-in-source markers vanish without changing
  the string.
- **Overlays only work on single-line fragments.** Drawing an image on a
  *multi-line* (wrapping) fragment re-triggers a layout pass that wedges it to
  one line. This is why a wrapping callout *custom title* has no icon — see
  `docs/callout-title-wrap-investigation.md` for the full saga.

---

## 6. Feature map (where to look)

| Area | Files |
| --- | --- |
| Editor core / state | `TextView/EditorTextView.swift` (+ many extensions) |
| Parsing | `Parsing/BlockParser.swift`, `SyntaxHighlighter*.swift`, `CodeHighlighter.swift`, `CodeSyntaxPalette.swift` (shared Tomorrow/One-Dark hex table — read by both the editor's `NSColor` palette and the HTML CSS generator) |
| Block model | `Model/Block.swift`, `Callout.swift`, `EditorTheme.swift`, `ListIndentState.swift` |
| Rendering | `Rendering/EditorTextView+*Rendering.swift` (Callout, Code, Image, List, Math, Table, WikiLinks) |
| Read mode / Export | `Export/` — `HTMLRenderer` (MarkupVisitor → HTML; callout/checkbox icons are inline Lucide SVGs from `LucideIcons`), `HTMLTheme` (EditorTheme → CSS), `DocumentHTML` (assembly + asset inlining: math + local images → data URIs), `ReadModeWebView`, `MarkdownPrinter` (PDF/Print). `Document.refreshReadView()` keeps an open Read view in sync with edits and theme changes. |
| Icons | `Model/LucideIcons.swift` — vendored [Lucide](https://lucide.dev) SVGs (ISC, `LICENSES/lucide.txt`). Callout headers use them in **both** modes: Read inlines the SVG (CSS-tinted via `currentColor`); Edit rasterizes to a tinted `NSImage` overlay. We *can't* ship SF Symbols in exported PDFs (license). App-chrome (toolbar/settings) SF Symbols are fine (in-app UI). Edit-mode task checkboxes still use SF Symbols (on-screen only); Read-mode checkboxes are a composed Lucide SVG. |
| Edit behaviors | `Editing/EditorTextView+{List,Blockquote}Continuation.swift`, `+Indentation.swift` |
| Formatting commands | `Editing/EditorTextView+Formatting{Core,Commands}.swift` (Format-menu actions: bold/lists/links/callouts/…); menu built from `edmd/App/FormatMenu.swift` |
| Lazy/compose/undo/scroll | `TextView/EditorTextView+{Composition,LazyStyling,Undo,TypewriterScroll,SelectionTracking,ContentWidth,EditFlow}.swift` |
| App shell | `edmd/App/{main,Document,DocumentController}.swift`; menu bar in `main.swift` `setupMenuBar()` + `FormatMenu.swift`; Sparkle `SPUStandardUpdaterController` in `AppDelegate` |
| Settings (SwiftUI) | `edmd/Settings/*` (AppSettings = UserDefaults keys; FontSettings; Appearance/General/Advanced views) |
| Auto-update | Sparkle 2.x. `Info.plist`: `SUFeedURL` (raw GitHub URL to `appcast.xml`), `SUPublicEDKey` (ed25519 public key). `scripts/release.sh`: build → zip → EdDSA sign → update appcast → `gh release create`. CI: `.github/workflows/release.yml` (tag-triggered). One-time setup: generate the EdDSA keypair with `generate_keys` (§8). |
| Status bar | `edmd/Views/StatusBarView.swift` |
| Build/packaging | `scripts/build-app.sh` (release build + Sparkle.framework embedding + signing), `Package.swift`, `Info.plist`, `Resources/` |

Notable subsystems: **typewriter scroll** (keeps caret vertically centered;
must lay out the viewport↔caret span before measuring or it reads stale TK2
height estimates), **content width** (`+ContentWidth.swift`: a settings slider
sets a symmetric `textContainerInset.width` for a centered reading column,
recomputed on resize).

**Format menu & shortcuts** are pure AppKit (the app has no SwiftUI scene, so
SwiftUI `Commands` isn't an option). `FormatMenu.swift` is a declarative command
table (`MenuCommand` + `Shortcut`, each with a stable `id` so a later pass can
read per-command shortcut overrides from UserDefaults) that builds the menu; items
use a nil target and route through the responder chain to the focused
`EditorTextView`'s `@objc format…` actions — the same wiring as undo/redo. Those
actions funnel through two primitives in `+FormattingCore.swift`
(`applyFormattingEdit` for a single contiguous edit, modeled on the Tab-indent
path; `applyWholeDocumentEdit` for non-contiguous edits like footnotes). The
View-menu ⌘E item cycles Edit→Read→Source via `Document.cycleViewMode`.

**Read mode is a separate WKWebView**, not an editor styling mode. Entering
`.reading` swaps the editor's scroll view for a `ReadModeWebView` that renders
the document as themed HTML (the `Export/` group); Edit and Source stay on the
`EditorTextView`. The HTML path walks the *same* swift-markdown `Document` the
editor parses (one parser, two back-ends: `SpanCollector` → editor attributes,
`HTMLRenderer` → HTML), themed from the *same* `EditorTheme`/`CalloutStyle` via
`HTMLTheme`, so the two can't drift. The webview disables JavaScript and inlines
every asset (math/icons as data URIs) so it needs no file/network reach; external
links open in the default browser. **File ▸ Export as PDF… / Print… (⌘P)** run
the same HTML through `WKWebView.printOperation` for real vector (selectable)
text — `MarkdownPrinter`. Math glyphs are high-DPI PNG (SwiftMath has no SVG
path yet); callout/checkbox icons are inline Lucide SVG (vector); everything
else is vector. Code blocks are syntax-colored by
`CodeHighlighter` (same tokenizer and `CodeSyntaxPalette` as Edit mode). Local
images are inlined as data URIs via a `baseURL` (document directory) threaded
through `DocumentHTML`/`ReadModeWebView`/`MarkdownPrinter`; remote images are
off by default (`ReadRenderOptions.allowRemoteImages`). `[[Wikilinks]]` and
relative markdown links use private URL schemes (`x-edmund-wiki:`,
`x-edmund-link:`) in the rendered HTML so the nav coordinator can intercept
them and route through the app's document graph without JavaScript.

---

## 7. Settings & persistence

- `AppSettings` (`edmd/Settings`) defines UserDefaults keys + typed accessors.
  SwiftUI panes use `@AppStorage`. Live changes broadcast to every open
  `Document.editor` (see the font/line-height/content-width `applyTo…` helpers).
- Theme/appearance/fonts flow into `EditorTheme` → the editor's derived
  `bodyFont`, colors, paragraph styles.
- **Diagnostic logging** (`EdmundCore/Diagnostics/Log.swift`): an always-on
  (opt-out) file logger. `Log.{debug,info,error}(_:category:)` and
  `Log.measure(_:) { … }` (single-line durations) write to
  `~/.edmund/logs/edmund-YYYY-MM-DD.log` on a private serial queue. One
  compile-time level threshold ships (DEBUG = `debug`+; release = `info`+) — the
  user only toggles it on/off and picks a retention window (Settings ▸ General ▸
  Diagnostics). `AppSettings.applyLogging()` pushes the toggle/retention into
  `Log.configure` at launch and on change; retention is pruned there.

---

## 8. Quirks & gotchas (will bite you)

- **SwiftMath fonts**: `build-app.sh` must copy `*.bundle` into the `.app` root
  (it does). Without it, the app **crashes the instant it renders any LaTeX**.
- **Sparkle codesign workaround**: `Contents/Frameworks/` triggers codesign's
  strict bundle-seal mode, which rejects the SwiftMath bundle at the `.app` root
  (required by its generated `Bundle.module` accessor — it's hardcoded to
  `Bundle.main.bundleURL`). The build script works around this by signing the
  main binary as a temporary standalone file rather than sealing the whole bundle.
  A Developer ID cert + notarization would fix it properly; ad-hoc signing is
  the current limit.
- **Sparkle keypair (one-time setup)**: the EdDSA public key in `Info.plist`
  `SUPublicEDKey` is a placeholder. See §8 for the exact commands to generate
  and install the real key before shipping an update.
- **Stale release builds**: `swift build -c release` / `build-app.sh` sometimes
  reuses stale object files (you'll run an old binary and be baffled). If a
  visual change "doesn't take," `rm -rf .build` and rebuild. `shasum` the binary
  to confirm it changed.
- **`open Edmund.app` foregrounds a *running* instance instead of relaunching.**
  Always `pkill -x edmd` first, or launch the binary directly
  (`build/Edmund.app/Contents/MacOS/edmd file.md &`).
- **Screencapture for visual verification**: capture a specific window by id
  (reliable even if not frontmost) via Quartz:
  `CGWindowListCopyWindowInfo` → find the window by `kCGWindowName` → `screencapture -x -o -l<id> out.png`.
  The desktop wallpaper defeats brightness-based auto-cropping; crop by the
  detected window bounds instead. Window-server state can glitch (tiny windows,
  state restoration) after many rapid launch/kill cycles — `rm -rf ~/Library/"Saved Application State"/com.i7t5.edmund.savedState` and relaunch.
- **Width not known at first styling**: on load the view may be unsized, so
  anything that bakes the content width (e.g. callout header images) renders at
  a fallback width until a width-settled re-render. Prefer real wrapping text
  over width-baked images where possible.
- **Attribute-only changes don't re-measure geometry in TK2**: after restyling a
  block whose height/indent changed, you must `invalidateLayout(for:)` its range
  or the fragment keeps a stale frame (empty bands / clipped lines). `recompose
  Dirty` and the idle drain already do this; new paths must too.
- **Never mutate storage while an IME is composing (`hasMarkedText()`)**: during
  composition the storage holds the provisional marked text, so `storage ==
  rawSource` is transiently false and `didChangeText` defers syncing until
  commit. Any styling that runs `beginEditing`/`setAttributes`/`invalidateLayout`
  mid-composition can strand the marked text in the input context — after which
  `didChangeText` keeps bailing on its own guard and the invariant stays broken,
  so every later edit drifts the caret (the old "delete-drift" bug). Every
  storage-touching styling path must guard `!hasMarkedText()` — including async
  ones scheduled *before* composition began (the caret-move restyle in
  `+SelectionTracking`). `becomeFirstResponder` resyncs from storage as a
  catch-all if a composition is ever left stranded. Full write-up:
  `docs/delete-drift-investigation.md`.

---

## 9. Known issues / lurking problems

- **Callout custom title can't show the type icon** (TextKit 2 multi-line +
  image wedge). Shipped workaround: custom titles wrap as real text *without*
  an icon; default callouts keep theirs. Full investigation + a preserved
  (non-working) image-based alternative on branch `fix/callout-title-image`:
  `docs/callout-title-wrap-investigation.md`.
- *(Add new ones here as you find them — with a one-line repro and a pointer to
  any deeper write-up in `docs/`.)*

## 10. Still to address

- Revisit the callout icon limitation if a newer macOS/TextKit 2 fixes the
  reentrancy (reproduce first; would require bumping the deployment target off
  macOS 14).
- *(Track larger roadmap items in README/ROADMAP; track code-debt here.)*

---

## 11. Quick start for an agent

1. Skim README (what/why), then this doc (how).
2. `swift build && swift test` — confirm green before changing anything.
3. Find the feature's `Rendering/` or `TextView/` extension via §6.
4. Make the change; add/adjust tests in `Tests/EdmundTests` (helpers:
   `makeEditor()`, `ensureFullLayout()`, `styleBlock()`).
5. Verify per §12 before committing.

---

## 12. Working agreements (pre-commit checklist)

Do these **before every commit** (this is the workflow that worked; deviate
only with reason):

1. **`swift test` is green** (all pass). Add tests for new behavior / bug repros.
2. **Visual changes are eyeballed** — build the app and `screencapture` the
   result (§8), or render offscreen to a PNG. Don't trust headless layout alone
   for anything that draws.
3. **Frequent, small, logical commits** — one feature/fix each. Don't discard uncommited changes. 
4. **Don't autopush, PR, or merge unless asked.** Branch off `main`
   (don't commit straight to it); each fix on its own branch.
5. Touch only what the task needs; match surrounding style; don't refactor
   unrelated code.

If you (the agent) improve this workflow or discover a better verification
trick, update this section.
