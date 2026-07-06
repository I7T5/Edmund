---
name: textkit2-appkit-reference
description: >
  Domain-theory pack for the AppKit text system as it applies to the Edmund
  Markdown editor. Load when working on layout, selection, IME, undo, drag, or
  eventing behavior; when TextKit 2 or NSTextView does something surprising;
  or when terms like NSTextLayoutManager, layout fragment, marked text, queued
  selection fixup, responder chain, or sendEvent appear and you lack AppKit
  text-system background. Explains the mechanisms the invariants and gotchas
  are built on. Not the invariants themselves (edmund-architecture-contract),
  not a triage table (edmund-debugging-playbook), not the repro drivers
  (edmund-live-repro-and-diagnostics).
---

# TextKit 2 / AppKit reference (as it applies to Edmund)

The background a mid-level engineer or Sonnet-class model usually lacks. Each
concept: brief theory, then **where it bites in Edmund** with a verified file
pointer. This is not a textbook — it is only the parts that matter here.

Facts checked against source 2026-07-05. Items labeled *(background)* are
general AppKit/TextKit behavior grounded in Apple's documentation, not directly
grep-able in this repo.

---

## 1. The TextKit 2 object model *(background + repo)*

TextKit 2 replaced the TextKit 1 `NSLayoutManager` stack. The players:

- **`NSTextContentStorage`** — owns the backing string + attributes (the model).
- **`NSTextLayoutManager`** — lays text out (the TK2 analogue of the old layout manager).
- **`NSTextLayoutFragment`** — one laid-out chunk (≈ a paragraph); has a real
  geometric frame **only once laid out**.
- **`NSTextElement` / `NSTextParagraph`** — the model-side elements fragments render.

**Viewport-based layout** is the headline difference: TK2 lays out only the
content near the visible viewport, not the whole document. That is what makes
big documents fast — and it is the root of most viewport pain (§2).

**Where it bites:** Edmund subclasses the fragment as `DecoratedTextLayoutFragment`
(`EditorTextView+TextKit2.swift`) to draw callout boxes, bars, and overlays.

---

## 2. Height ESTIMATES — the master cause of viewport glitches

A fragment that has not been laid out yet has an **estimated** height, not a
real one; the total document height is the sum of real + estimated fragment
heights. As layout reaches a fragment, its estimate is replaced by the true
value and everything below shifts. Consequences: the scroller thumb jumps, and
"scroll to offset Y" lands wrong because Y was computed from estimates. This is
a **widely documented TK2 limitation — even TextEdit shows it** *(background)*.

**Where it bites / Edmund mitigations** (verify names by grep; all in `TextView/`):
- `fullLayoutMaxLength = 100_000` (`EditorTextView.swift:80`): documents ≤ 100k
  UTF-16 units are kept **fully laid out** (no estimate regime) by a coalesced
  next-run-loop settle.
- `scheduleFullLayoutSettle` / `preservingViewportAnchor`: the settle runs inside
  an anchor block so corrections never shift what is on screen.
- `repairContentAboveOrigin` (`+LazyStyling.swift`, logs `repairing content
  above origin`): fixes the case where an edit near the top strands the first
  fragment at negative y (unreachable above the scroller top).
- `centerViewportOnCaret`: re-measures after its first scroll and corrects the
  residual estimate error.

**Rule:** never trust an off-screen fragment's y-coordinate without laying out
its span first. Deep write-up: `docs/viewport-glitch-investigation.md`.

---

## 3. The TextKit 1 fallback trap

An `NSTextView` can silently and **permanently** revert from TK2 to the legacy
TK1 stack. Two known triggers: **accessing `NSTextView.layoutManager`** (the
mere getter engages TK1), and **storing `NSTextBlock`/`NSTextTable`
attributes**. Once reverted, TK2 APIs still exist but do nothing useful, and the
whole editor misbehaves subtly.

**Where it bites:** Edmund ships a **DEBUG tripwire** — an observer on
`NSTextView.willSwitchToNSLayoutManagerNotification` that asserts if the switch
happens (`EditorTextView.swift:273`+, message "TextKit 1 fallback triggered").
Never add code that reads `layoutManager` or stores table attributes; draw
tables as decorations instead (`EditorTextView+TableRendering.swift`).

---

## 4. Attribute-only mutation semantics

Edmund renders by writing **attributes** onto the storage, never by inserting or
deleting characters (the storage == rawSource invariant). Two consequences from
the text system:

- **`setAttributes` does not re-measure geometry.** After a restyle that changes
  a block's height or indent, you must call `invalidateLayout(for:)` on its
  range or the fragment keeps a **stale frame** (empty bands / clipped lines).
  `recomposeDirty` and the idle drain already do this; new paths must too.
- **`NSTextAttachment` is only honored on the `U+FFFC` object-replacement
  character** *(background)*. `rawSource` never contains `U+FFFC`, so attachments
  can't be used — Edmund draws images/icons as **overlays** (§5) instead.

---

## 5. The custom drawing model (fragments, decorations, overlays)

`DecoratedTextLayoutFragment` draws two attribute families behind/over text:

- **`.blockDecoration`** (paragraph-level): callout boxes, quote bars, table
  borders, thematic-break rules, code backgrounds. Fragments **tile vertically**,
  so a multi-line run renders as one continuous box. A box's `bottomPad` grows
  the **last** fragment's frame (TK2 omits trailing paragraph spacing from the
  fragment, so padding done otherwise would be dead space).
- **`.fragmentOverlay`** (character-level): an image **or** a stroked vector path
  drawn at a glyph's laid-out position — rendered math, list bullets/checkboxes,
  callout header icon, the custom-title callout icon (path). The anchor glyph is
  **hidden** (≈0.01 pt font + clear color) and `.kern` reserves the drawing's
  advance width.

**The image-on-wrapping-fragment wedge:** drawing an **image** overlay on a
**multi-line (wrapping)** fragment re-triggers a layout pass that collapses the
fragment to one line. Drawing a **shape/path** does not. So the wrapping
callout title's icon is a stroked `CGPath` (parsed by `SVGPath` from vendored
Lucide geometry), never an image. Full saga:
`docs/callout-title-wrap-investigation.md`. This constraint holds for **any new
overlay** that could share a line with wrapping text.

**Hiding text** = `hiddenFont` (≈0.01 pt) + clear `foregroundColor`. This is how
delimiters (`**`, `` ` ``, `[!note]`) vanish without changing the string.

---

## 6. The queued selection fixup (the round-6 delete-drift mechanism)

When you mutate an `NSTextView`'s storage, AppKit queues a private step,
`-[NSTextLayoutManager _fixSelectionAfterChangeInCharacterRange:]`, that repairs
the selection against the new character coordinates. Normally it fires promptly.
But if an edit **bypasses the normal close-out** (see §7), the fixup stays
**queued** and fires at the **next `endEditing`** — *even an attribute-only
restyle* — where it maps the now-**stale** selection against post-edit
coordinates and **leaps the caret blocks away**. It will move even a freshly set,
valid caret.

**Where it bites:** this is delete-drift round 6. The heal must set the caret
(from the pendingEdit hull) **before** the sync **and re-assert it after**
(`EditorTextView+EditFlow.swift`). Recognize a variant by: a suspicious
selection change arriving mid-recompose (`up=Y` in traces);
`traceSelectionOrigin` will log the call stack of whoever moved it.

**Critical for testing:** a headless test harness runs this deferred fixup
**synchronously**, so this bug class **cannot reproduce in a unit test** — the
round-6 regression test passes with *and* without the fix. Only the live
in-process repro discriminates (edmund-live-repro-and-diagnostics).

---

## 7. The AppKit edit pipeline contract (and where AppKit breaks it)

Normal edit: `shouldChangeText(in:replacementString:)` → the view calls
`replaceCharacters` → `didChangeText()`. Edmund's `didChangeText` syncs
`rawSource` from storage and restyles the edited block(s).

**AppKit does NOT always send `didChangeText`.** A drag-move of selected text
whose drop lands on **no valid target** (e.g. released past the end of the
document) deletes the dragged range via `shouldChangeText` → `replaceCharacters`
and **never calls `didChangeText`** — silently freezing `rawSource`/`blocks`,
after which every edit drifts and autosave writes stale content (delete-drift
round 4). Edmund heals this: `shouldChangeText` schedules a next-run-loop
**bypass check** (`scheduleBypassedEditSyncCheck`, `+EditFlow.swift`); an
unconsumed storage `pendingEdit` by then means the close-out never came, and the
editor runs the sync itself (breadcrumb: `healing storage edit that bypassed
didChangeText`).

**Never build a sync path on the assumption that `didChangeText` follows every
edit.**

**The authentic key route** *(background + repo)*: keyDown →
`interpretKeyEvents` → `insertText:` / `deleteBackward:`. This is why the repro
driver synthesizes real `NSEvent`s and pushes them through `window.sendEvent(_:)`
rather than calling `insertText` directly — shortcuts skip `deleteBackward`'s
selection machinery, which is exactly where round 6 lived.

---

## 8. IME / marked text lifecycle

While an input method is composing (e.g. CJK, accents), the view holds
**provisional "marked" text** in storage; `hasMarkedText()` is true. During this
window `storage == rawSource` is **transiently false**, and `didChangeText`
defers syncing until the composition commits.

**The cascade:** any styling path that runs
`beginEditing`/`setAttributes`/`invalidateLayout` **mid-composition** can strand
the marked text in the input context. After that, `didChangeText` keeps bailing
on its own guard and the invariant stays broken — so **every later edit drifts
the caret** (the original delete-drift bug). Therefore **every storage-touching
styling path must guard `!hasMarkedText()`** — including async ones scheduled
*before* composition began (the caret-move restyle in `+SelectionTracking`).
`becomeFirstResponder` resyncs from storage as a catch-all. Full write-up:
`docs/delete-drift-investigation.md`.

---

## 9. Responder chain & nil-target actions *(background + repo)*

The **responder chain** is AppKit's search order for who handles an action.
Menu items and toolbar buttons with a **nil target** send their action up the
chain until something responds. Edmund's Format menu (`FormatMenu.swift`) is a
declarative command table whose items use nil targets and route to the focused
`EditorTextView`'s `@objc format…` actions — the same wiring as undo/redo. The
first responder is normally the focused `EditorTextView`.

---

## 10. `NSWindow.sendEvent` — the pre-toolbar event funnel

Every event a window receives passes through `sendEvent(_:)` **before** the
toolbar acts. This matters because with `NSToolbar.allowsUserCustomization =
true`, the toolbar claims **any secondary (right/control) click over the
toolbar** — including a custom item view — for its own "Customize Toolbar…" menu,
downstream of view-level handlers (`menu`, `rightMouseDown`, gesture
recognizers all lose). Edmund's fix for the view-mode button: intercept in
`DocumentWindow.sendEvent(_:)`, pop the menu when the click is inside the
button's bounds, and swallow it (`return`); other clicks fall through to
`super`. (Caveat: true fullscreen moves the toolbar to a separate window, so
this main-window hook wouldn't cover it.)

---

## 11. Drag sessions *(background + repo)*

- **Text drag-move arming:** AppKit only starts a text drag after a **mouse-down
  hold (~400 ms)**; a CGEvent driver must hold before moving or the drag never
  arms.
- **Drag-select autoscroll:** dragging past the viewport edge autoscrolls.
- **Reveal at nearest end:** a selection taller than the viewport must be
  revealed at its **nearest** end (Edmund's `scrollRangeToVisible` override) —
  always revealing the top fought the drag-select autoscroll and oscillated the
  viewport mid-drag.

---

## 12. swift-markdown walker model *(brief)*

Edmund parses with `apple/swift-markdown` (CommonMark/GFM) and walks the
resulting `Document` with **two back-ends**: a `SpanCollector`-style walk that
produces editor attributes, and `HTMLRenderer` that produces HTML for Read mode.
One parser, two outputs — so Edit and Read can't drift. Custom (non-CommonMark)
syntax — callouts, `==highlight==`, wikilinks, comments, footnotes, math — is
handled by `SyntaxHighlighter+CustomParsers.swift`.

---

## When NOT to use this skill

- The project's **rules/invariants** (what you must not do) → **edmund-architecture-contract**.
- **Which** symptom means which mechanism → **edmund-debugging-playbook**.
- **Reproducing** a live bug / reading traces → **edmund-live-repro-and-diagnostics**.
- The **history** of how these mechanisms were discovered → **edmund-failure-archaeology**.
- Running the caret-integrity campaign → **edmund-caret-integrity-campaign**.

---

## Provenance and maintenance

Verified 2026-07-05. Re-verify the load-bearing identifiers:

```bash
grep -n 'fullLayoutMaxLength' Sources/EdmundCore/TextView/EditorTextView.swift
grep -n 'willSwitchToNSLayoutManager' Sources/EdmundCore/TextView/EditorTextView.swift
grep -n 'scheduleBypassedEditSyncCheck\|healing storage edit' Sources/EdmundCore/TextView/EditorTextView+EditFlow.swift
grep -rn 'repairContentAboveOrigin\|preservingViewportAnchor' Sources/EdmundCore/TextView/
grep -rn 'blockDecoration\|fragmentOverlay\|hiddenFont' Sources/EdmundCore/
grep -rn 'hasMarkedText' Sources/EdmundCore/TextView/
```

Items marked *(background)* are AppKit/TextKit behavioral facts documented by
Apple and in `docs/*-investigation.md`, not directly observable by grep. If any
Edmund mitigation name above no longer greps, it was renamed — update this file
and `docs/ARCHITECTURE.md` §5/§8 together.
