---
name: edmund-research-frontier
description: >
  Open problems where the Edmund Markdown editor could advance the state of the
  art — product-first, everything labeled candidate/open, nothing proven. Load
  when picking the next big problem, evaluating whether an ambitious idea is
  worth starting, or answering "what would move this project beyond state of the
  art". Each frontier: why current SOTA fails, Edmund's specific asset, the
  first three concrete steps IN THIS REPO, and a falsifiable "you have a result
  when…" milestone. Not for running an accepted investigation
  (edmund-caret-integrity-campaign), the method of proof
  (edmund-research-methodology), or shipping the change (edmund-change-control).
---

# Edmund research frontier

Where Edmund could go past the state of the art. Ambition is **product-first**:
"the CotEditor of Markdown editors" (README). Advanced TextKit 2 techniques are
**means, not ends** — a technique is worth pursuing when it makes the product
better, and it becomes publishable as a side effect.

**Everything here is candidate / open. Nothing is proven.** Each item routes its
proof through **edmund-research-methodology** (hypothesis predicts numbers) and
its changes through **edmund-change-control**. Verified 2026-07-05 against the
repo; assets cited are real, outcomes are not.

---

## Frontier 1 — Viewport-stable TextKit 2 at scale (>100k UTF-16)

**Why SOTA fails:** TK2 lays out only near the viewport; off-screen fragment
heights are **estimates** corrected as layout reaches them. This makes the
scroller jump and scroll-to-target miss in **every** TK2 app, including TextEdit
— a widely documented limitation. Above `fullLayoutMaxLength` (100k) Edmund
enters this regime.

**Edmund's asset:** the mitigations already in `TextView/` —
`scheduleFullLayoutSettle`, `preservingViewportAnchor`, `repairContentAboveOrigin`,
`centerViewportOnCaret` re-measure, and the diff-based undo restore that avoids
resetting fragments to estimates; plus the `ScrollStabilityTests` /
`HeightStabilityTests` harnesses. (Note: `repairContentAboveOrigin` is
**mitigated-unconfirmed live** per `docs/investigations/viewport-glitch-investigation.md` — a
real result here would also *retire that honest gap*.)

**First three steps in this repo:**
1. Build a large-doc fixture (`makeLargeMarkdown` in `TestHelpers.swift`) >100k
   and a scripted scroll-accuracy metric (ReproScript `caret` + a `logsel`-style
   position dump, or extend `PerfHarnessTests`).
2. Quantify the estimate-error distribution: for N scroll-to-target operations,
   record predicted vs actual landing pixel offset.
3. Prototype persistent per-fragment height caching across the settle (or across
   sessions) and re-measure the same distribution.

**You have a result when:** scroll-to-target lands within a stated pixel budget
on a 1 MB document, measured by script, with **zero** `repairing content above
origin` events across a scroll soak — reproducibly.

---

## Frontier 2 — Caret integrity by construction

**Why SOTA fails:** every `NSTextView` consumer depends on `didChangeText`
pairing that **AppKit itself violates** (the drag-move bypass). The delete-drift
class is the symptom of building sync on a callback contract AppKit doesn't keep.

**Edmund's asset:** the heal machinery, the `pendingEdit` model, six documented
rounds of mechanism knowledge, and the ReproScript + soak methodology. The
campaign skill runs *individual* rounds reactively; this frontier is the
**structural endgame** — eliminate the class.

**First three steps:**
1. Inventory **every** storage-mutation entry point (grep `replaceCharacters`,
   `setAttributes`, the edit-flow paths) and tabulate which currently rely on a
   callback firing.
2. Design a sync layer keyed on a **storage-version counter** that reconciles
   `rawSource` regardless of which callbacks fired (not a new guard per path).
3. Falsify it against **all** historical `.repro` scripts plus a new randomized
   bypass-fuzzer script.

**You have a result when:** all historical `.repro` scripts and a randomized
bypass soak stay green **with the callback-pairing assumption deleted from the
code**. **Candidate, big** — likely a multi-PR redesign; do not start without the
methodology skill's evidence bar in front of you.

---

## Frontier 3 — The 10 MB class (performance headroom)

**Why it matters:** README claims "~1–2 MB files"; native-with-no-Electron is the
differentiator, so headroom is a product claim, not vanity.

**Edmund's asset:** viewport-based lazy styling, the idle drain, incremental
reparse (`pendingEdit` window), `PerfHarnessTests`.

**First three steps:**
1. Extend `PerfHarnessTests` with 5/10 MB fixtures (`makeLargeMarkdown`).
2. Profile the block-parse and restyle hot paths (`Log.measure` single-line
   durations are already in place).
3. Set explicit latency budgets for open, first-paint, and per-keystroke restyle
   at 10 MB.

**You have a result when:** open + steady-state typing latency on a 10 MB file
meets a stated budget, measured by the harness (not hand-timed).

---

## Frontier 4 — A native extensions API

**Why SOTA fails:** Obsidian/VS Code plugin ecosystems are Electron; there is no
strong precedent for a **native, safe, fast** extension surface for live-preview
Markdown on macOS. ROADMAP v1.0.0 lists "Extensions API, documentations,
primitive marketplace" and flags Advanced Syntax Highlighting / Advanced Math as
"official extension" candidates.

**Edmund's asset:** the custom-parser seam
(`Parsing/SyntaxHighlighter+CustomParsers.swift`), the `BlockKind`/`styleBlock`
architecture, and already-modular opt-in syntax (math, Obsidian syntax).

**First three steps:**
1. Catalog which existing features could be **re-implemented as extensions**
   (dogfood: callouts? highlight? wikilinks?) — this defines the real extension
   points.
2. Define the minimal seam: block parser? inline parser? theme hook? Draw the
   line at what the custom-parser architecture already supports.
3. Spike **one** official extension behind a flag and measure restyle cost vs the
   built-in.

**You have a result when:** one built-in syntax feature runs as an extension with
**no measurable restyle regression** against the built-in baseline.

---

## Frontier 5 — Accessibility / RTL / localization as a differentiator

**Why it matters:** native apps *can* excel where Electron editors are weak;
ROADMAP v1.x lists Localization, RTL, Accessibility. Locale-aware content width
already ships as precedent that the pipeline can be locale-sensitive.

**Edmund's asset:** the attribute-only pipeline (structure is in the string, not
in inserted characters), the existing locale-aware content-width path.

**First three steps:**
1. VoiceOver audit of `EditorTextView`'s custom drawing — does the accessibility
   tree expose headings/lists/callouts, given they're drawn as decorations?
2. Test RTL behavior of the attribute-only styling on a right-to-left document.
3. Scriptable a11y check (structure read-out) as a regression guard.

**You have a result when:** a scripted VoiceOver audit reads document structure
(headings, list items, callouts) correctly on a mixed document.

---

## How to start one

1. **Predict numbers first** (edmund-research-methodology §2) — every milestone
   above is a *number*, not a vibe.
2. Instrument to make the current failure/limit cheap to measure.
3. Prototype behind a flag; measure predicted vs observed.
4. Route changes through **edmund-change-control** (branch, tests, no auto-push).
5. When the first milestone lands, the item **graduates to `misc/backlog.md` or
   `docs/ROADMAP.md`** and stops being a frontier.

## What NOT to start (no current asset)

- **iOS / iPadOS port** — explicitly **TBD** in ROADMAP; no shared UI layer today.
- **Collaborative / real-time editing** — zero repo support (no CRDT, no sync,
  single `NSDocument` model). Would be a new product, not a frontier of this one.
- Anything that requires breaking an invariant (storage == rawSource; TextKit 2
  only) to work — that's not a frontier, it's a rewrite (edmund-architecture-contract).

---

## When NOT to use this skill

- Running an *accepted* investigation (a known bug) → **edmund-caret-integrity-campaign** / **edmund-debugging-playbook**.
- The method of turning a hunch into proof → **edmund-research-methodology**.
- Whether a public claim is allowed yet → **edmund-external-positioning**.
- Shipping the change → **edmund-change-control**.

---

## Provenance and maintenance

Verified 2026-07-05. Assets exist; **outcomes are unproven by definition** —
never quote a milestone here as achieved.

```bash
grep -n 'fullLayoutMaxLength' Sources/EdmundCore/TextView/EditorTextView.swift
grep -rn 'repairContentAboveOrigin\|preservingViewportAnchor' Sources/EdmundCore/TextView/
ls Sources/EdmundCore/Parsing/SyntaxHighlighter+CustomParsers.swift
grep -n 'Extensions API\|RTL\|Localization\|iPadOS' docs/ROADMAP.md
grep -rn 'func makeLargeMarkdown' Tests/EdmundTests/TestHelpers.swift
```

When an item's milestone lands, move it to ROADMAP/backlog and delete it here —
a frontier list that keeps solved problems is lying.
