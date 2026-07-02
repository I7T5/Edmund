# Edmund — architecture & agent onboarding

A native macOS Markdown editor with live preview (AppKit + TextKit 2, SPM,
macOS 14+). This doc gets an AI agent productive fast: read it before any
non-trivial change. **Keep it updated** — when you learn something non-obvious
or change an invariant, edit this file in the same PR.

---

## 1. Build / run / test

```bash
swift build                 # debug build of both targets
swift test                  # full suite (≈750+ tests, ~10s)
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
                                          │   comments, footnotes, math, backslash
                                          │   escapes, inline HTML tags)
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
| Crash-log uploading | `EdmundCore/Diagnostics/CrashReporter.swift` (see §7) |
| Auto-update | Sparkle 2.x. `Info.plist`: `SUFeedURL` (raw GitHub URL to `appcast.xml`), `SUPublicEDKey` (ed25519 public key). `scripts/release.sh`: build → DMG (sindresorhus `create-dmg`, **npm** — not the homebrew tool) → EdDSA sign → update appcast → `gh release create`. The DMG is the Sparkle enclosure (it mounts the image and installs the `.app` inside). CI: `.github/workflows/release.yml` (tag-triggered). Full pipeline, signing, and the `RELEASE_TOKEN` PAT: §13. |
| Status bar | `edmd/Views/StatusBarView.swift` |
| Build/packaging | `scripts/build-app.sh` (release build + Sparkle.framework embedding + signing), `Package.swift`, `Info.plist`, `Resources/` |

Notable subsystems: **typewriter scroll** (keeps caret vertically centered;
must lay out the viewport↔caret span before measuring or it reads stale TK2
height estimates — and re-centers only on *typing*, not on clicks: a mouse-down
sets `suppressTypewriterCentering` so positioning the caret by clicking doesn't
yank the viewport), **content width** (`+ContentWidth.swift`: an **absolute
physical** max-column width — set in cm/in in Settings, stored as cm, converted
to points via the display's real PPI (`NSScreen.physicalPPI`, from
`CGDisplayScreenSize`). It's a CSS `max-width` cap applied as a symmetric
`textContainerInset.width`: windows wider than the cap center the column,
narrower ones fill. Recomputed on resize and when the window moves to a
differently-scaled display (`NSWindow.didChangeScreenNotification`)).

**Format menu & shortcuts** are pure AppKit (the app has no SwiftUI scene, so
SwiftUI `Commands` isn't an option). `FormatMenu.swift` is a declarative command
table (`MenuCommand` + `Shortcut`, each with a stable `id` so a later pass can
read per-command shortcut overrides from UserDefaults) that builds the menu; items
use a nil target and route through the responder chain to the focused
`EditorTextView`'s `@objc format…` actions — the same wiring as undo/redo. Those
actions funnel through two primitives in `+FormattingCore.swift`
(`applyFormattingEdit` for a single contiguous edit, modeled on the Tab-indent
path; `applyWholeDocumentEdit` for non-contiguous edits like footnotes). The
View-menu ⌘E item (and the toolbar button) *toggles* the editing view ↔ Read
via `Document.toggleViewMode`. **Source is not a third toggle stop** — it's a
persisted preference (`AppSettings.sourceMode`, a "Source Mode" checkbox in the
View menu and the toolbar button's right-click menu): when on, the editing half
of the toggle is Source instead of Edit (so ⌘E flips Source ↔ Read), and a
freshly opened document honors it. The toolbar's view-mode button left-clicks to
toggle and right-clicks for the full mode menu (see the §8 gotcha on why that
right-click is intercepted in `DocumentWindow.sendEvent`). The toolbar enables
`allowsUserCustomization` (Customize Toolbar… is an AppKit `NSToolbar` feature,
not a SwiftUI one).

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
- **Max content width** persists as **centimetres** (`maxContentWidthCm`); the
  cm/in shown in Settings is a display unit (`contentWidthUnit`), the column
  itself is always physical (see §6 content width). Default is 12 cm / 5 in.
- **Window size** persists as the last document window's full **frame** size
  (`lastWindowSize`) — see the §8 gotcha on why it's the frame, not the content
  size.
- **Diagnostic logging** (`EdmundCore/Diagnostics/Log.swift`): an always-on
  (opt-out) file logger. `Log.{debug,info,error}(_:category:)` and
  `Log.measure(_:) { … }` (single-line durations) write to
  `~/.edmund/logs/edmund-YYYY-MM-DD.log` on a private serial queue. One
  compile-time level threshold ships (DEBUG = `debug`+; release = `info`+) — the
  user only toggles it on/off and picks a retention window (Settings ▸ General ▸
  Diagnostics). `AppSettings.applyLogging()` pushes the toggle/retention into
  `Log.configure` at launch and on change; retention is pruned there.
- **Crash-log uploading** (`EdmundCore/Diagnostics/CrashReporter.swift`): opt-in
  (default off), fire-and-forget upload of the `.ips` crash reports macOS writes
  to `~/Library/Logs/DiagnosticReports/`. On launch, if `AppSettings.sendCrashLogs`
  is true, we POST any `edmd-*.ips` files not in `AppSettings.sentCrashReports`
  (dedup) to `CrashReporter.reportingEndpoint`. Note: `edmd` is the Mach-O
  executable name (not "Edmund") — that's the prefix in crash-report filenames.
  **The Settings ▸ Advanced toggle is currently commented out** (the `// Crash
  reports:` GridRow in `AdvancedSettingsView.swift`); uncomment it and replace the
  placeholder `reportingEndpoint` URL once the receiving server exists. The upload
  path reads `~/Library/Logs/DiagnosticReports/` directly, which only works
  because the app is not sandboxed; if App Sandbox is ever adopted, switch to
  MetricKit's `MXCrashDiagnostic` API instead.

---

## 8. Quirks & gotchas (will bite you)

- **SwiftMath fonts**: `build-app.sh` must copy `*.bundle` into the `.app` root
  (it does). Without it, the app **crashes the instant it renders any LaTeX**.
- **Sparkle codesign — must seal the whole bundle**: at install time Sparkle
  re-validates the downloaded update's Apple code signature
  (`SUUpdateValidator`). Even with a valid EdDSA signature, a bundle that reports
  as code-signed but fails `SecStaticCodeCheckValidity` is rejected as *"The
  update is improperly signed and could not be validated."* The old build script
  signed only the main binary as a standalone file and never sealed the bundle —
  so it had no `_CodeSignature/CodeResources` and **every Sparkle update failed**
  (the v0.1.0→0.1.1 update error). The fix: `build-app.sh` seals the whole `.app`
  (`codesign --deep`). The obstacle is the SwiftMath resource bundle, which must
  sit at the `.app` root (its generated `Bundle.module` accessor is hardcoded to
  `Bundle.main.bundleURL`), and codesign refuses to seal a bundle with any item
  at the root. So we seal while the root holds only `Contents/`, then copy the
  SwiftMath bundle in **after** signing. That one unsealed root item makes
  `codesign --verify` (CLI) and `--strict` complain, but Sparkle's actual check
  is non-strict (`SecStaticCodeCheckValidityWithErrors` with
  `kSecCSCheckAllArchitectures`) and tolerates it — verified against that exact
  API. A Developer ID cert + notarization would be cleaner; ad-hoc is the current
  limit.
- **Sparkle keypair**: set up and verified — public key in `Info.plist`
  `SUPublicEDKey`, private key in the login keychain and the CI secret
  `SPARKLE_ED_PRIVATE_KEY`. Don't let them diverge. Full release/signing details
  in §13.
- **`create-dmg` — npm only, three quirks**:
  - Install via **npm** (`npm install --global create-dmg`), not Homebrew — they
    are different tools with incompatible CLIs. Requires Node ≥20 (`node --version`).
  - Exits **2** (not 0) when it can't Developer-ID-sign the image (we ship
    ad-hoc). It still produces the `.dmg`; `release.sh` and the CI step both
    use `|| true` and then verify the file exists.
  - Names the output `"Edmund <version>.dmg"` (space, not hyphen). Both scripts
    rename it to `Edmund-<version>.dmg` before signing and uploading.
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
- **AppKit does not pair every storage mutation with `didChangeText`.** A
  drag-move of the selected text whose drop lands on no valid target (e.g.
  released past the end of the document) deletes the dragged range via
  `shouldChangeText` → `replaceCharacters` and **never calls `didChangeText`**
  — silently freezing `rawSource`/`blocks`, after which every edit drifts the
  caret and autosave writes the stale `rawSource` (delete-drift round 4).
  `shouldChangeText` therefore schedules a next-run-loop bypass check: a
  storage `pendingEdit` still unconsumed by then means the closing
  `didChangeText` never came, and the editor heals by running the same sync
  (`+EditFlow`, `scheduleBypassedEditSyncCheck`; `healing storage edit that
  bypassed didChangeText` in `~/.edmund/logs` is its breadcrumb). Never build
  a sync path on the assumption that `didChangeText` follows every edit.
- **A custom toolbar item can't win a right-click from a view-level handler.**
  With `NSToolbar.allowsUserCustomization = true`, the toolbar turns any
  secondary (right / control) click over the toolbar — *including* a custom item
  view — into its own "Customize Toolbar…" context menu. Setting the view's
  `menu`, overriding `rightMouseDown`, and a secondary-button
  `NSClickGestureRecognizer` **all lose**, because the toolbar claims the click
  downstream of them. The fix (view-mode button): intercept in
  `DocumentWindow.sendEvent(_:)` — the documented funnel every window event
  passes through *before* the toolbar acts — and when the click falls inside the
  button's bounds, pop the menu and `return` (swallow it). Other right-clicks
  fall through to `super`. (Caveat: in true fullscreen the toolbar moves to a
  separate window, so this main-window hook wouldn't cover that case.)
- **Window-size persistence must round-trip the frame, not the content size.**
  Saving `contentView.bounds.size` and re-applying it as the initializer's
  `contentRect` makes the window grow by the title-bar + (unified) toolbar height
  on every reopen — and content heights below the frame `minSize` get silently
  rejected. Save `window.frame.size` and re-apply it with `window.setFrame(_:)`
  **after the toolbar is installed** (the frame is only final then), so frame-in
  == frame-out (`windowDidResize` ↔ `makeWindowControllers` in `Document.swift`).

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
- **Inline HTML renders in both modes for a fixed whitelist** —
  `SyntaxHighlighter.htmlFormatTags` (`u`/`kbd`/`mark`/`sub`/`sup`), the single
  source of truth. Edit: `parseHTMLTags` colors any tag (name red, brackets
  dimmed) and renders the whitelist by hiding the tags + styling the inner
  content. Read: `HTMLRenderer.sanitizeInlineHTML` passes the same whitelist
  through as *bare* tags (attributes dropped — defense-in-depth; the read webview
  also disables JS); every other inline tag and **all** block HTML
  (`visitHTMLBlock`) stays escaped. `<br>` and non-whitelisted tags are
  color-only in Edit / escaped in Read (a real `<br>` break would need to mutate
  storage, breaking the storage==rawSource invariant). Minor divergence: an
  *unpaired* whitelist tag is color-only source in Edit but follows browser HTML
  balancing in Read.
- **Edit-mode table alignment** distributes each cell's slack via `.kern`,
  putting the right/center "before" pad on the cell's *hidden* leading pipe
  (0.01pt glyph) — kern still adds advance there. See
  `EditorTextView+TableRendering.swift`.
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

---

## 13. Release & CI pipeline

How a release happens, plus the non-obvious things that broke shipping 0.1.0.

**Flow (tag-triggered).** Push a `vX.Y.Z` tag → `.github/workflows/release.yml`
(`macos-14`): build the `.app` (`build-app.sh`) → DMG (npm `create-dmg`) →
EdDSA-sign the DMG → `gh release create` (notes are the matching `CHANGELOG.md`
section, extracted by `awk`) → commit the new `<item>` into `appcast.xml` on
`main`. `scripts/release.sh` mirrors this locally but leaves the appcast
commit/push to you. The new `<item>` also gets a `<description>` (HTML release
notes from the CHANGELOG section, via `scripts/changelog-to-html.py`) so
Sparkle's update dialog shows the changelog in its scrollable pane.

**To cut a release:** bump `CFBundleShortVersionString` / `CFBundleVersion` in
`Info.plist`, add a `## [x.y.z]` section to `CHANGELOG.md`, merge to `main`,
then `git tag vx.y.z && git push origin vx.y.z`.

**EdDSA keypair — set up, not a placeholder.** The keypair exists. The public
key is in `Info.plist` `SUPublicEDKey` (`0XdLbbuO…`); the private key lives in
two places that must stay the *same* keypair: the maintainer's **login
keychain** (used by `release.sh` locally, no flag) and the GitHub Actions secret
**`SPARKLE_ED_PRIVATE_KEY`** (used by CI). Verified end-to-end: a CI-signed DMG
verifies against the `Info.plist` public key (`sign_update --verify <dmg> <sig>`).
If the signing key and `SUPublicEDKey` ever diverge, the DMG signs fine but every
user's update fails signature verification.

**Signing flag — `sign_update -s` is fatal for newly generated keys.** Sparkle's
`sign_update` deprecated `-s <key>`; for keys generated after that change it
prints only a deprecation warning and **exits 1** ("no longer supported"). This
killed the first 0.1.0 release. Feed the key on **stdin** instead — both
`release.yml` and `release.sh` now use:
`echo "$SPARKLE_ED_PRIVATE_KEY" | sign_update --ed-key-file - <dmg>`.

**Appcast push to protected `main` needs an admin PAT.** `main` requires the
`test` status check. The workflow's last step commits the appcast update and
pushes to `main`, but the default `GITHUB_TOKEN` / `github-actions[bot]` is not
an admin, so the required check rejects it (`GH006 … protected branch hook
declined`). `main` protection has `enforce_admins: false`, so an **admin's**
push bypasses the check — `release.yml`'s **checkout step** therefore
authenticates with a fine-grained admin PAT in the **`RELEASE_TOKEN`** secret
(Contents: read/write). Set it on *checkout*, not by rewriting the push URL:
`actions/checkout` persists an `http.<host>.extraheader` credential that
otherwise overrides inline-URL creds, so the push would keep using the bot
token. **`RELEASE_TOKEN` expires 2027-06-27** — rotate it before then or
releases fail at the appcast push.

**Gatekeeper / notarization.** The app is ad-hoc signed, not notarized, so users
hit Gatekeeper on first launch; the README documents the
`xattr -dr com.apple.quarantine` / right-click-Open workarounds. A Developer ID
cert + notarization (see §8) would remove the prompt entirely.
