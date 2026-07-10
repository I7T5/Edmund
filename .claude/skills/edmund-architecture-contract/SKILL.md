---
name: edmund-architecture-contract
description: >
  The load-bearing design contract of the Edmund Markdown editor. Load BEFORE
  any non-trivial code change in this repo; when asking "why is it built this
  way"; before proposing a new mechanism, subsystem, or refactor; whenever you
  are tempted to insert/strip display characters, use NSTextAttachment, touch
  NSTextView.layoutManager, store NSTextBlock/NSTextTable attributes, or add a
  new overlay/decoration; and before designing anything that syncs storage,
  selection, undo, or the viewport. Covers the two hard invariants
  (storage == rawSource; TextKit 2 only), the render pipeline, edit/undo flow,
  the TextKit 2 drawing model, the read-mode contract, and the known weak
  points. Not for build/run/release mechanics, debugging triage, or live-repro
  drivers — see "When NOT to use this skill".
---

# Edmund architecture contract

Edmund is a native macOS Markdown editor with live preview: AppKit +
TextKit 2, SwiftPM, macOS 14+. Two targets (`Package.swift`):

| Target | Role |
| --- | --- |
| `EdmundCore` | Library: parsing, rendering, `EditorTextView`, all tests. Most work happens here. |
| `edmd` | Executable: `NSDocument` app shell, Settings (SwiftUI), menus. Note: `edmd` is the Mach-O binary name; the app is "Edmund". |

Project ambition (maintainer, 2026-07-05): product-first — "the CotEditor of
Markdown editors". Bias toward polish of the editing experience over feature
count. The hardest live problem class to date is **delete-drift**
(caret/selection integrity, 6 investigation rounds); the costliest failures
were delete-drift and undo/redo viewport drift. Every rule below traces to one
of those scars.

Ground truth this file distills: `docs/ARCHITECTURE.md` (repo root).
Treat that doc as authoritative if the two ever disagree, and fix this skill.

## Glossary (each term defined once)

- **rawSource** — the document's Markdown text, the single source of truth
  (`EditorTextView.rawSource`).
- **storage** — the `NSTextStorage` the text view displays
  (`EditorTextStorage`, `Sources/EdmundCore/TextView/EditorTextStorage.swift`).
- **Block** — one logical Markdown block (paragraph, heading, list run, code
  fence, table, quote/callout run). Model: `Sources/EdmundCore/Model/Block.swift`.
- **Active block** — the block under the caret; it renders its *raw* markdown
  (delimiters visible/editable) while all others render styled.
- **Recompose** — restyling storage from `blocks`
  (`Sources/EdmundCore/TextView/EditorTextView+Composition.swift`).
- **Fragment** — an `NSTextLayoutFragment`, TextKit 2's per-paragraph layout
  unit. Off-screen fragments have *estimated* heights until laid out.
- **Overlay** — an image or stroked path drawn at a character's laid-out
  position by the custom fragment class (see §4), replacing what
  `NSTextAttachment` would do in TextKit 1.
- **Delete-drift** — the bug class where `rawSource`/storage/selection desync
  and every later edit lands the caret in the wrong place. Chronicle:
  `docs/investigations/delete-drift-investigation.md`.
- **IME composition** — an input method's provisional "marked text"
  (`hasMarkedText()`), present in storage before the user commits it.

---

## 1. The two non-negotiable invariants

Break either and the editor misbehaves in subtle, delayed ways. Every design
review starts here.

### Invariant 1 — storage == rawSource (attribute-only rendering)

The displayed text storage is *always* character-identical to `rawSource`.
Rendering only ever adds/changes **attributes**. Delimiters (`**`, `` ` ``,
`[!note]`, …) are **hidden, never stripped**: `hiddenFont` (0.01pt system
font, `Sources/EdmundCore/Rendering/EditorTextView+Rendering.swift:55`) plus a
clear `foregroundColor` makes them invisible without touching the string.

**Rationale.** Identity mapping between display offsets and raw offsets means
there is no offset-translation layer — caret math, selection, undo diffs,
incremental reparse, and autosave all operate on one coordinate system.

**Consequences you must respect:**

| Consequence | Why |
| --- | --- |
| No `NSTextAttachment`, ever | TextKit 2 only honors attachments on U+FFFC (OBJECT REPLACEMENT CHARACTER), which `rawSource` never contains. Images, math, bullets, checkboxes, icons are drawn as **overlays** instead (§4). |
| No inserted display characters | A synthesized `<br>`, bullet glyph, or padding character would desync offsets. Use attributes (`.kern`, paragraph styles) or overlays. |
| Never mutate storage while IME is composing | During composition, storage holds marked text so the invariant is *transiently* false and `didChangeText` defers syncing. Styling that runs `beginEditing`/`setAttributes`/`invalidateLayout` mid-composition strands the marked text; the invariant then stays broken and every later edit drifts the caret. Every storage-touching styling path — including async ones scheduled before composition began — must guard `!hasMarkedText()`. |

**The incident.** The original delete-drift bug: an async restyle fired during
IME composition, stranded the marked text, `didChangeText` kept bailing on its
own guard, and the invariant stayed silently broken — caret drift on every
subsequent edit. `becomeFirstResponder` now resyncs from storage as a
catch-all. Full write-up: `docs/investigations/delete-drift-investigation.md`.

### Invariant 2 — TextKit 2 only

Never touch `NSTextView.layoutManager` (the TextKit 1 `NSLayoutManager`
accessor) and never store `NSTextBlock`/`NSTextTable` attributes. Either one
**silently and permanently reverts the view to TextKit 1** — no error, no log,
just different (and wrong-for-us) layout from then on.

**Rationale.** All custom drawing rides `NSTextLayoutFragment` subclassing
(§4), and viewport-based layout (only on-screen content laid out) is what
makes large documents fast. Both are TextKit 2 facilities; a TK1 fallback
kills them.

**The tripwire.** DEBUG builds observe
`NSTextView.willSwitchToNSLayoutManagerNotification` and `assertionFailure`
if the fallback ever triggers —
`textKit1FallbackTripwire(_:)`,
`Sources/EdmundCore/TextView/EditorTextView.swift:272-303`. If you see that
assertion, some code path you touched used a TK1 API or attribute. Find it;
do not suppress the assert.

Corollary: Edit-mode tables cannot use `NSTextTable`. Alignment is done by
distributing slack via `.kern` on hidden pipe glyphs —
`Sources/EdmundCore/Rendering/EditorTextView+TableRendering.swift`.

---

## 2. Render pipeline

```
rawSource ──BlockParser──▶ [Block] ──styleBlock per block──▶ attributed runs in storage
                                        │
                                        └─ SyntaxHighlighter (swift-markdown walker
                                           + custom parsers: callouts, ==highlight==,
                                           wikilinks, comments, footnotes, math,
                                           backslash escapes, inline HTML tags)
```

| Stage | Where |
| --- | --- |
| Block splitting | `Sources/EdmundCore/Parsing/BlockParser.swift` — `parse(_:previous:)`, `parseWithDiff(...)` |
| Span production | `Sources/EdmundCore/Parsing/SyntaxHighlighter.swift` + `+Walker.swift` / `+WalkerInline.swift` / `+CustomParsers.swift` |
| One-block render | `styleBlock(_:cursorPosition:...)`, `Sources/EdmundCore/Rendering/EditorTextView+Rendering.swift:151`; per-feature extensions in `Sources/EdmundCore/Rendering/` (Callout, Code, Image, List, ListMarker, Math, Table, WikiLinks) |
| Orchestration | `Sources/EdmundCore/TextView/EditorTextView+Composition.swift` |

Recompose entry points (pick the narrowest that works — a full `recompose`
resets every fragment height to an estimate, see §6):

| Function | Scope | Used for |
| --- | --- | --- |
| `recompose(cursorInRaw:)` | Whole document | Load, indent — never for undo (§3) |
| `recomposeDirty(_:cursorInRaw:)` | A set of block indices, in place | The workhorse; attribute-only |
| `recomposeIncremental(cursorInRaw:...)` | The block(s) the caret moved between | Most cursor moves |
| `recomposeReplacing(oldRange:with:...)` | One contiguous text span | Undo/redo restore |

**Lazy styling** (`Sources/EdmundCore/TextView/EditorTextView+LazyStyling.swift`):
a large dirty set styles only the viewport synchronously; the rest is finished
by the **idle drain** (time-budgeted main-thread slices) and **scroll
promotion** (style blocks as they enter the viewport).

Gotcha: attribute-only changes do **not** re-measure geometry in TextKit 2.
If a restyle changed a block's height/indent, call `invalidateLayout(for:)`
on its range or the fragment keeps a stale frame. `recomposeDirty` and the
idle drain already do this; any new path must too.

---

## 3. Edit flow & undo

Normal edit: `shouldChangeText` (records a coalesced undo snapshot) →
NSTextView mutates storage → `didChangeText` syncs `rawSource` and restyles
the edited block(s) (`Sources/EdmundCore/TextView/EditorTextView+EditFlow.swift`,
`+Composition.swift`). Edits capture a `pendingEdit` on `EditorTextStorage`
and reparse a window, not the whole document.

**Undo/redo is custom** (`Sources/EdmundCore/TextView/EditorTextView+Undo.swift`):
stacks of `rawSource` snapshots, bypassing NSTextView's built-in undo.
Restoring diffs the snapshot against current text (`textDiff(old:new:)`,
single contiguous span) and applies it with the range-bounded
`recomposeReplacing` — **never a full `recompose`**, because a full recompose
resets every fragment to a TextKit 2 height estimate and the follow-up scroll
lands wrong (this was the undo/redo viewport-drift failure). The changed text
drives the viewport: hold if any of it is on-screen, else center it.

**AppKit does NOT pair every storage mutation with `didChangeText`.** Proven
incident (delete-drift round 4): a drag-move of selected text dropped on no
valid target deletes the dragged range via `shouldChangeText` →
`replaceCharacters` and never calls `didChangeText` — silently freezing
`rawSource`/`blocks`; every later edit drifts the caret and autosave writes
stale text. The heal: `shouldChangeText` schedules a next-run-loop
**bypass check** (`scheduleBypassedEditSyncCheck`, `+EditFlow.swift`) — a
`pendingEdit` still unconsumed by then means the closing `didChangeText`
never came, and the editor runs the same sync itself. Breadcrumb in
`~/.edmund/logs`: `healing storage edit that bypassed didChangeText`.
**Never build a sync path on the assumption that `didChangeText` follows
every edit.**

Round 6 corollary: a bypassed edit also leaves TextKit 2's private selection
fixup (`_fixSelectionAfterChangeInCharacterRange:`) queued; it fires at the
**next** `endEditing` — even an attribute-only restyle — and leaps the caret
blocks away, moving even a freshly set valid caret. The heal sets the caret
before the sync **and re-asserts it after** (`+EditFlow.swift`). This class
does not reproduce headless; see the routing in §8.

---

## 4. TextKit 2 drawing model

All custom visuals are drawn by `DecoratedTextLayoutFragment` (custom
`NSTextLayoutFragment`,
`Sources/EdmundCore/TextView/EditorTextView+TextKit2.swift:160`), vended via
the layout-manager delegate. Two custom attribute keys (same file, lines
28/32):

| Attribute | Level | Draws | Rules |
| --- | --- | --- | --- |
| `.blockDecoration` | Paragraph | Callout boxes, quote bars, table borders, thematic-break rules, code backgrounds | Fragments **tile vertically** so a multi-line run reads as one continuous box/bar. A box's `bottomPad` grows the **last** fragment's own frame — TextKit 2 omits trailing paragraph spacing from the fragment, so padding done any other way is dead space. |
| `.fragmentOverlay` | Character | An image **or stroked vector path** at a character's laid-out position: rendered math, list bullets/checkboxes, callout header icon+name image, custom-title callout icon (path) | The anchor glyph is hidden (`hiddenFont` + clear color) and `.kern` reserves the drawing's advance width — the same trick the table renderer uses. |

**The image-wedge constraint (open, not solved).** Drawing an *image* overlay
on a *multi-line (wrapping)* fragment re-triggers a layout pass that wedges
the fragment to one line. Drawing a *shape* (stroked `CGPath`) does not.
That is why the wrapping callout custom-title icon is a stroked path parsed
from vendored Lucide geometry, never an image. **Any new overlay that could
share a line with wrapping text must be a shape, not an image.** Full saga:
`docs/investigations/archives/callout-title-wrap-investigation.md`.

---

## 5. Read mode contract

Read mode is a separate `WKWebView`, not an editor styling mode
(`Sources/EdmundCore/Export/`). The contract: **one parser, two back-ends** —
the *same* swift-markdown `Document` the editor parses is walked by
`SyntaxHighlighter.SpanCollector` (→ editor attributes) and by `HTMLRenderer`
(→ HTML), themed from the *same* `EditorTheme` via `HTMLTheme`, so the two
renderings cannot drift. When adding a feature, implement it in **both**
back-ends or document the divergence.

Hard properties of the web view (keep them):
- **JavaScript disabled**; every asset inlined (math as high-DPI PNG data
  URIs — SwiftMath has no SVG path; icons as inline Lucide SVG) so it needs
  no file/network reach. Remote images off by default
  (`Sources/EdmundCore/Export/ReadRenderOptions.swift`).
- **Private URL schemes** route navigation without JS:
  `x-edmund-wiki:` / `x-edmund-link:`
  (`Sources/EdmundCore/Export/HTMLRenderer.swift:26,31`).
- Inline HTML: only the whitelist `SyntaxHighlighter.htmlFormatTags`
  (`u`/`kbd`/`mark`/`sub`/`sup`,
  `Sources/EdmundCore/Parsing/SyntaxHighlighter.swift:22`) renders in either
  mode; everything else stays escaped/color-only. A real `<br>` break would
  need to mutate storage — forbidden by Invariant 1.
- Export/Print run the same HTML through `WKWebView.printOperation`
  (`Sources/EdmundCore/Export/MarkdownPrinter.swift`) for vector text.

---

## 6. Known weak points (open as of 2026-07-05)

State these plainly when designing near them; none is solved.

1. **TextKit 2 height estimates** are the root of most viewport glitches: an
   off-screen fragment's frame (and the total document height) is an estimate
   until layout reaches it — scroller jumps, scroll-to-target lands wrong (a
   documented TK2 limitation; TextEdit shows it too). Mitigations in place,
   not cures: documents ≤ `fullLayoutMaxLength` (100k UTF-16,
   `Sources/EdmundCore/TextView/EditorTextView.swift:80`) are kept fully laid
   out by `scheduleFullLayoutSettle()` wrapped in `preservingViewportAnchor`
   (`+LazyStyling.swift:121`, `+TypewriterScroll.swift:22`);
   `repairContentAboveOrigin()` (`+LazyStyling.swift:151`) fixes content
   stranded above y=0; `centerViewportOnCaret` re-measures after its first
   scroll. **Never trust an off-screen fragment's y-coordinate without laying
   out the span first.**
2. **The image-wedge constraint** (§4) applies to every new overlay.
3. **Open bugs** (`misc/backlog.md`): callout at end-of-file renders an extra
   un-prefixed line in the callout color (live incremental-restyle path, not
   static rendering); footnotes don't render in either mode; attached images
   create blank space below; math doesn't render in read mode (and has wrong
   padding in edit mode); delete caret drift and viewport-estimate glitches
   remain on the ongoing list.
4. **Crash reporter endpoint is a placeholder**:
   `CrashReporter.reportingEndpoint` is `https://REPLACE-ME.invalid/crash`
   (`Sources/EdmundCore/Diagnostics/CrashReporter.swift:27`) and the
   Settings ▸ Advanced toggle is commented out
   (`Sources/edmd/Settings/AdvancedSettingsView.swift`). Do not treat crash
   uploading as live.

---

## 7. Before you design something new — checklist

Run this before proposing any new mechanism, subsystem, or refactor:

- [ ] **Invariant 1**: does it insert/strip characters, use
      `NSTextAttachment`, or mutate storage outside the
      shouldChangeText→didChangeText path (or during IME composition)? If
      yes, redesign as attributes/overlays.
- [ ] **Invariant 2**: does it touch `NSTextView.layoutManager` or store
      `NSTextBlock`/`NSTextTable`? If yes, stop.
- [ ] **Sync assumptions**: does it assume `didChangeText` follows every
      mutation, or that a set caret stays put across the next `endEditing`?
      Both assumptions are proven false (§3).
- [ ] **Geometry**: does it read an off-screen fragment frame, or restyle
      without `invalidateLayout(for:)` when height changed? (§2, §6.)
- [ ] **Both back-ends**: does a rendering feature cover Edit *and* Read
      (§5)?
- [ ] **Prior art**: check ARCHITECTURE.md §14 — especially
      [nodes-app/swift-markdown-engine](https://github.com/nodes-app/swift-markdown-engine),
      an independent AppKit+TextKit 2 live-preview engine solving the same
      problems — before inventing a new mechanism for an editing-experience
      problem.
- [ ] **Weak points** (§6): does the design lean on anything listed there?
      Label it as such; unproven mitigations are "open/candidate", never
      "fixed".
- [ ] **Verification plan**: unit test if headless can repro; otherwise plan
      a live repro (ReproScript) — do not ship a caret/IME/viewport fix on
      reasoning alone. Visual claims are measured from `screencapture`
      pixels, not eyeballed.

Process rules live in sibling skills, but never contradict them here: branch
per fix off `main`; never auto-push/PR/merge; `swift test` green + visual
verification before commit; never blanket `pkill -x edmd` (the maintainer's
daily-driver app shares the binary name — `pgrep` and kill only your own
PID); never request macOS Computer Access permissions.

---

## When NOT to use this skill

| You need… | Use instead |
| --- | --- |
| Whether/how to gate a change, commit discipline, scope control | `edmund-change-control` |
| A symptom → cause triage path for a bug you're seeing | `edmund-debugging-playbook` |
| The blow-by-blow history of a past investigation | `edmund-failure-archaeology` |
| TextKit 2 / AppKit theory beyond Edmund's specific contract | `textkit2-appkit-reference` |
| Launch flags, debug bundles, defaults keys | `edmund-config-and-flags` |
| Build, stale-binary cures, screencapture mechanics, environment setup | `edmund-build-and-env` |
| Cutting a release, Sparkle/appcast/CI | `edmund-release-and-operate` |
| Driving a live repro (ReproScript, CGEvent, log tracing) | `edmund-live-repro-and-diagnostics` |
| Test-writing patterns, QA passes | `edmund-validation-and-qa` |
| Docs style, ARCHITECTURE.md upkeep | `edmund-docs-and-writing` |
| Positioning, comparisons, marketing claims | `edmund-external-positioning` |
| The caret/selection-integrity campaign specifically | `edmund-caret-integrity-campaign` |
| How to investigate an unknown (method, not facts) | `edmund-research-methodology` / `edmund-research-frontier` |

---

## Provenance and maintenance

Facts verified against the repo on 2026-07-05. If a grep below stops
matching, the fact drifted — update this file and cite the new location.

```bash
# Invariant 2 tripwire still present
grep -n "textKit1FallbackTripwire" Sources/EdmundCore/TextView/EditorTextView.swift
# Recompose entry points
grep -n "func recompose" Sources/EdmundCore/TextView/EditorTextView+Composition.swift
# Bypass heal
grep -n "scheduleBypassedEditSyncCheck" Sources/EdmundCore/TextView/EditorTextView+EditFlow.swift
# Custom draw attributes + fragment class
grep -n "blockDecoration\|fragmentOverlay\|class DecoratedTextLayoutFragment" Sources/EdmundCore/TextView/EditorTextView+TextKit2.swift
# hiddenFont hiding trick
grep -n "hiddenFont" Sources/EdmundCore/Rendering/EditorTextView+Rendering.swift
# Viewport mitigations
grep -n "fullLayoutMaxLength" Sources/EdmundCore/TextView/EditorTextView.swift
grep -n "scheduleFullLayoutSettle\|repairContentAboveOrigin" Sources/EdmundCore/TextView/EditorTextView+LazyStyling.swift
# Read-mode schemes + HTML whitelist
grep -n "wikiScheme\|linkScheme" Sources/EdmundCore/Export/HTMLRenderer.swift
grep -n "htmlFormatTags" Sources/EdmundCore/Parsing/SyntaxHighlighter.swift
# Crash-reporter placeholder (delete §6.4 once this is a real URL)
grep -n "REPLACE-ME.invalid" Sources/EdmundCore/Diagnostics/CrashReporter.swift
# Open-bug list
sed -n '/^Bugs/,/^UI\/UX/p' misc/backlog.md
```
