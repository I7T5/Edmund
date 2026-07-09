---
name: edmund-validation-and-qa
description: >
  What counts as EVIDENCE in the Edmund Markdown editor, and how to add tests.
  Load when writing or adjusting tests, deciding what proof a fix needs before
  it can ship, judging whether a change is actually "verified", interpreting
  the test suite, or adding a golden/regression check. Covers the evidence
  hierarchy (headless is necessary but not sufficient for live-input bugs),
  the test-suite map, the Swift Testing helpers, how to add a test, the golden
  inventory, visual QA, and performance evidence. Not the gating rules
  themselves (edmund-change-control) or how to run the live repro
  (edmund-live-repro-and-diagnostics).
---

# Edmund validation & QA

The discipline of proof. The central lesson: **a green headless test is
necessary but not sufficient** for the bug classes that cost the most time here.
Know which evidence each change actually requires.

Framework: **Swift Testing** (`import Testing`, `@Test`, `#expect`, `#require`)
— NOT XCTest. Verified 2026-07-05: 810 `@Test` cases across `Tests/EdmundTests/`.

---

## 1. The evidence hierarchy

Ordered weakest → strongest. The rule at the bottom names which class each
change type **requires**.

| Class | What it proves | Blind spot |
|---|---|---|
| (a) Headless unit test (`makeEditor()`) | model/parse/style/undo logic | **Cannot** exercise deferred AppKit machinery — runs it synchronously |
| (b) Windowed unit test (real NSWindow + NSScrollView, real `deleteBackward`) | + layout, viewport, first responder | still not real event-loop pacing / IME / drag |
| (c) Frozen live ReproScript repro (exact script + document) | the live input/timing mechanism | needs a debug build + ~1 min/run |
| (d) Soak script green across 4–5 cycles, byte-identical final `rawLen` | armed-state + determinism | slow |
| (e) Screencapture pixel measurement | anything that DRAWS | manual |

**The trap that defines this skill:** the delete-drift **round-6 regression test
passes with AND without the fix** — the harness runs the queued selection fixup
synchronously, so headless can't see the bug. For caret/IME/drag/viewport-timing
bugs, class (a) is not evidence of a fix; you need (c)+(d).

**Required evidence by change type** (gates enforced in edmund-change-control):

| Change | Requires |
|---|---|
| Pure logic (parse/style/model) | (a) |
| Viewport/lazy-layout | (b), often (e) |
| Anything that draws | (a where testable) + **(e)** in light AND dark |
| Edit-pipeline / selection / IME / undo | (a) to lock the headless contract **+ (c)** frozen repro **+ (d)** soak |
| Release | see edmund-release-and-operate |

---

## 2. Test-suite anatomy

Run: `swift test` (full suite; ARCHITECTURE cites ~750+ tests ≈10s — 810 `@Test`
cases as of 2026-07-05). One suite: `swift test --filter <Suite>`. **`swift test`
also runs automatically as a Stop hook** (`.Codex/settings.json`) at the end of
any turn touching code, so failures surface before you commit.

Map of `Tests/EdmundTests/` (what the files actually cover):

- **Parsing:** `BlockParserTests`, `SyntaxHighlighterTests`, `IncrementalParseFuzzTests`, `PendingEditTests`, `EscapeRenderingTests`, `HTMLTagRenderingTests`, `EmojiRenderingTests`, `LineEndingTests`.
- **Rendering / styling:** `BlockStylingTests`, `CalloutRenderingTests`, `CalloutTests`, `CommentRenderingTests`, `NestedBlockStylingTests`, `InlineStylingTests`, `MathRenderingTests`, `ImageRenderingTests`, `CodeHighlighterTests`, `FootnoteTests`, `WikiLinkTests`, `TableAlignmentTests`, `RenderingRegressionTests`.
- **Editor behavior:** `EditorIndentationTests`, `ListContinuationTests`, `BlockquoteContinuationTests`, `BlockquoteDeletionTests`, `FormattingTests`, `ActiveBulletMarkerTests`, `NewListItemAlignmentTests`.
- **Edit-pipeline integrity (the costly class):** `BypassedEditSyncTests`, `MarkedTextDesyncTests`, `WrappedParagraphCaretTests`, `EditorDiagnosticsTests`, `UnmatchedDebugTests`, `InternationalInputTests`.
- **Viewport / layout / undo:** `LazyRenderingTests`, `ScrollStabilityTests`, `HeightStabilityTests`, `TypewriterCenteringTests`, `UndoRedoViewportTests`, `EditorUndoTests`, `RecomposeTests`, `RecomposeEquivalenceTests`.
- **Export / read mode:** `HTMLRendererTests`, `DocumentHTMLTests`, `ReadModeWebViewTests`, `HTMLThemeTests`, `EditorThemeTests`, `ViewModeTests`, `ContentWidthTests`.
- **Infra / harness:** `LogTests`, `CrashReporterTests`, `PerfHarnessTests`, `StatusBarPrefsTests`, `FileIntegrationTests`, `EditorDocumentTests`, `TestHelpers.swift`. `_RenderDump.swift` / `_RenderEdit.swift` are **local dev tools (gitignored intent)** that dump Read-mode HTML / edit output for `tmp/sample.md` — not part of the assertion suite.

**Two invariant-guarding patterns worth copying:**
- **Recompose equivalence** (`RecomposeEquivalenceTests`, helper
  `assertMatchesFullRecomposeOracle`): an incremental restyle must produce the
  **same** result as a full recompose. This is the safety net for the lazy /
  incremental styling paths.
- **Incremental-parse fuzz** (`IncrementalParseFuzzTests`): random edits must
  keep the parser's window-reparse consistent with a full reparse.

---

## 3. Test helpers (`TestHelpers.swift`)

`@MainActor` helpers you build on (verified exports):

| Helper | Use |
|---|---|
| `makeEditor()` | an `EditorTextView` on the real TK2 chain (mirrors `Document.makeWindowControllers`) |
| `ensureFullLayout(...)` | force layout so geometry is real, not estimated |
| `type(...)`, `paste(...)`, `pressEnter()`, `pressBackspace()` | drive edits |
| `activateBlock(...)` | move the caret / active block |
| `displayText(...)`, `attrs(...)`, `font(...)`, `fgColor(...)` | inspect styled output |
| `isHidden` / `isInvisible` / `isDimmed` | assert delimiter hiding |
| `blockDecoration(...)`, `textBlockDifference(...)` | inspect decorations / catch TK1-reverting table attrs |
| `expectedFullComposition(...)`, `drainAllStyling()`, `assertMatchesFullRecomposeOracle(...)` | equivalence-oracle checks |
| `makeLargeMarkdown(...)`, `sentence(...)` | build big fixtures for perf/viewport |

`styleBlock(_:cursorPosition:)` is a method on `EditorTextView`
(`Rendering/EditorTextView+Rendering.swift`), called from tests — it renders one
block to an attributed string.

---

## 4. How to add a test

Skeleton (Swift Testing, `@MainActor` because the editor is main-thread):

```swift
import Testing
import AppKit
@testable import EdmundCore

@MainActor
@Test func deletingAtCalloutBottomKeepsInvariant() {
    let editor = makeEditor()
    editor.loadRawSource("> [!note]\n> body\n")
    drainAllStyling()
    // ... drive the edit ...
    #expect(editor.rawSource == editor.string)   // storage == rawSource invariant
}
```

Rules:
1. **Every bug fix ships with a test even if it can't discriminate a live-only
   mechanism** — it still locks the headless contract so a *future* refactor
   can't silently re-break the model half. For the live half, keep the frozen
   `.repro` script alongside (edmund-live-repro-and-diagnostics).
2. Assert the **invariant** where you can (`rawSource == string`), not just the
   surface symptom — that's what `BypassedEditSyncTests` / `MarkedTextDesyncTests`
   do.
3. Name the test for the behavior/bug, put edit-pipeline repros next to their
   siblings (the `*Desync*` / `*Bypassed*` / `*CaretTests` families).
4. New drawing behavior additionally needs a screencapture check (§6).

---

## 5. Golden / certified inventory

- **`RenderingRegressionTests`** + `RecomposeEquivalenceTests` are the closest
  thing to golden checks — they pin styled output and incremental-vs-full
  equivalence.
- **`test-files/*.md`** (`callout.md`, `decorations.md`, `math.md`, `menu.md`,
  `test.md`) are the **user's manual test corpus** — hand-testing fodder. **Do
  not rewrite them to fit an automated test**; build your own fixtures (helpers
  in §3, or a scratch dir).
- **`misc/bug-repros/`** holds field evidence (`.mov` screen recordings + `.log`
  traces) for open bugs — reference these when reproducing, don't delete them.

---

## 6. Visual QA

Anything that draws is verified by **screencapture pixel measurement**, in
**light AND dark mode** (per `misc/before-you-release.md`), never by eyeballing
headless layout. Method + scripts: **edmund-live-repro-and-diagnostics** §5.
Headless layout tests (`HeightStabilityTests`, `ScrollStabilityTests`) check
geometry numbers but **cannot** confirm the pixels are right.

---

## 7. Flakiness & CI

- A `fix/flaky-math-test` branch exists in history — math rendering has shown
  timing flakiness; if a math test flakes, check that branch's approach before
  inventing a new one (verify: `git log --oneline --all -- '*Math*'`).
- CI: `.github/workflows/ci.yml` on `macos-14`, latest-stable Xcode, SPM cache
  keyed on `Package.resolved`, `concurrency: cancel-in-progress` (private-repo
  macOS minutes bill 10×). CI runs the same `swift test`.

---

## 8. Performance evidence

- **`PerfHarnessTests`** measures the hot paths; `makeLargeMarkdown` builds big
  fixtures. Use it (don't hand-time) for any perf claim.
- The README claim "handles ~1–2MB files" and `fullLayoutMaxLength = 100_000`
  UTF-16 (`EditorTextView.swift:80`) mark the boundary between the **full-layout**
  regime (≤100k, geometry is real) and the **estimate** regime (>100k, viewport
  glitches possible). A perf/viewport claim must state which regime it was
  measured in.

---

## When NOT to use this skill

- The gate/branch/commit rules → **edmund-change-control**.
- Running the live repro or measuring pixels → **edmund-live-repro-and-diagnostics**.
- The caret-integrity investigation end to end → **edmund-caret-integrity-campaign**.
- Why a mechanism works → **textkit2-appkit-reference** / **edmund-architecture-contract**.
- Release verification → **edmund-release-and-operate**.

---

## Provenance and maintenance

Verified 2026-07-05.

```bash
grep -rh '@Test' Tests/EdmundTests/*.swift | wc -l         # ~810 cases
grep -c 'import Testing' Tests/EdmundTests/TestHelpers.swift # confirms Swift Testing, not XCTest
grep -oE 'func [a-zA-Z]+' Tests/EdmundTests/TestHelpers.swift # helper inventory (§3)
ls Tests/EdmundTests/                                        # suite map (§2)
grep -n 'fullLayoutMaxLength' Sources/EdmundCore/TextView/EditorTextView.swift
```

If a helper in §3 no longer greps it was renamed; update §3 and any test
skeletons. Re-derive the suite map from `ls` if files are added/removed.
