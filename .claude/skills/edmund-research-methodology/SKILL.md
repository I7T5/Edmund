---
name: edmund-research-methodology
description: >
  The discipline that turns a hunch into an accepted result in the Edmund
  Markdown editor — the evidence bar, hypothesis-predicts-numbers, the
  first-principles analysis recipes, the idea lifecycle, and where good ideas
  historically came from. Load when forming a hypothesis about a bug's
  mechanism, evaluating whether an investigation's conclusion is trustworthy,
  deciding if a fix is actually proven, or turning an idea into an accepted
  change. This skill also absorbs the proof-and-analysis toolkit (prove it,
  don't just install it). Not the caret-integrity campaign itself
  (edmund-caret-integrity-campaign), not the repro tooling
  (edmund-live-repro-and-diagnostics).
---

# Edmund research methodology

How a hunch becomes something you can ship without it coming back. Every method
here is grounded in a real episode from this repo's history — the discipline was
paid for in the six delete-drift rounds and the viewport work.

Verified 2026-07-05 against `docs/delete-drift-investigation.md`,
`docs/viewport-glitch-investigation.md`, and `docs/live-repro-guide.md`.

---

## 1. The evidence bar

A mechanism is **accepted** only when it clears both bars:

1. **It explains ALL observations, including the negatives.** Not just "the caret
   drifts" but *why headless tests pass, why it's intermittent, why it appears
   minutes after the trigger.* A mechanism that explains the symptom but not the
   negatives is incomplete — and incomplete mechanisms come back.
2. **It survives assigned adversarial refutation.** Before shipping, actively try
   to **falsify** the supposed fix: run the frozen repro against it. Rounds 1–5
   of delete-drift shipped on reasoning and **all came back**; round 6's first
   fix candidate "worked by reasoning" and **failed in the repro within a
   minute** (`docs/delete-drift-investigation.md` round 6, "the iteration that
   proved its shape").

Corollary: **headless-green is not the bar** for live-input bugs — the round-6
regression test passes with and without the fix. See edmund-validation-and-qa
for the evidence hierarchy.

---

## 2. Hypothesis predicts numbers BEFORE running

State the expected observable **before** the experiment. An experiment without a
predicted number is a fishing trip.

- **Worked example:** round-6 `logsel` predicted **321** on the broken build vs
  **290** on the fixed build — a specific number, stated before the run, that the
  repro then confirmed every time.
- **Determinism as a prediction:** a soak's final `rawLen` must be
  **byte-identical** across runs; predict it, then check it.

If you can't name the number your hypothesis predicts, you don't understand the
mechanism well enough to test it yet — go back to instrumentation (§3b).

---

## 3. The analysis recipes (prove it, don't just install it)

Each: when to use, the steps, and the episode that earned it.

### 3a. Trace archaeology — walk BACKWARDS
**When:** any symptom with diagnostics on. **Steps:** find the first *bad* line,
then read *upward/earlier*, not forward from the symptom. **Episode:** the round-6
drift at 22:13 was armed by a bypass at 22:11:57 — 80 seconds and dozens of
healthy edits earlier. Source: `docs/live-repro-guide.md` §2.

### 3b. Make the failure cheap to observe before reasoning about fixes
**When:** you're tempted to guess. **Steps:** add one breadcrumb (a call stack, a
state dump) behind `Log.shouldTrace` and ship it; reproduce; let the log name the
culprit. **Episode:** `traceSelectionOrigin` named `_fixSelectionAfterChange` in
a single run after five rounds of guessing. This is *the* meta-lesson: **time
spent making the failure cheap to observe beats time spent reasoning about the
fix.**

### 3c. The fidelity ladder as an inference tool
**When:** a repro fails. **Steps:** a repro that fails at level N but succeeds at
N+1 **localizes** the mechanism to what N lacks. **Episode:** delete-drift not
reproducing in a windowed unit test (level 2) told the team it needed
deferred/queued AppKit state → pointed straight at level-3 in-process replay and
event-ordering hypotheses. Source: `docs/live-repro-guide.md` §1.

### 3d. Invariant auditing
**When:** the behavior looks impossible. **Steps:** find which invariant
**transiently broke** — `storage == rawSource` during IME composition;
`didChangeText` pairing during a drag-move; grep the guard inventory
(`hasMarkedText`, bypass checks). Lock it with an equivalence/fuzz oracle:
`RecomposeEquivalenceTests` (`assertMatchesFullRecomposeOracle` — incremental
restyle must equal a full restyle) and `IncrementalParseFuzzTests` (random edits
keep window-reparse == full reparse).

### 3e. Exact-sequence replication
**When:** simulating an AppKit-internal path. **Steps:** replay its **real call
sequence**, pinned from a stack trace, not an approximation of its *effect*.
**Episode:** `bypassdelete` reproduces `shouldChangeText`→`replaceCharacters`
with no `didChangeText` **verbatim** — an approximation would have hidden the bug.

### 3f. Differential measurement over eyeballing
**When:** any visual or binary claim. **Steps:** screencapture **pixel**
measurement for visuals (edmund-live-repro-and-diagnostics §5); `shasum`
before/after for "did the binary actually change"; predicted-vs-observed tables
for numbers. **Episode:** the maintainer's rule — when told "balance the padding",
measure the top vs bottom pad in pixels, don't judge by eye.

---

## 4. The idea lifecycle

How an idea moves from hunch to settled (or to a documented dead end):

```
hunch
  → cheap instrumentation / discriminating experiment (§3b, §3c)
  → investigation-doc entry (docs/<topic>-investigation.md, round structure)
  → frozen deterministic repro
  → fix on its own fix/ branch, with test + soak (edmund-validation-and-qa)
  → ARCHITECTURE §8 gotcha entry in the SAME PR (if an invariant changed)
  → settled status in the chronicle (edmund-failure-archaeology)
```

**Retirement path for ideas that fail:** a documented dead end in the
investigation doc with a "do not retry" note and *why* (see the round chronicle
and the viewport doc's "Verification limits (honest gaps)" section — mitigations
that are real but **unconfirmed live** are labeled so, not oversold).

**Where larger ideas are tracked:** `docs/ROADMAP.md` (versioned feature plan)
vs `misc/backlog.md` (near-term working list; priority order **Marketing = Bugs
>= UI/UX > Features**). A frontier idea graduates onto one of these when its
first milestone lands (edmund-research-frontier).

---

## 5. Where good ideas historically came from

Mine these seams first — they've paid out repeatedly:

- **Making failures observable.** The diagnostics accumulated one breadcrumb at a
  time; each named a mechanism the previous round guessed at.
- **Reading Apple's *actual* behavior, not the documented ideal.** Sparkle's
  update validation is non-strict (`SecStaticCodeCheckValidityWithErrors`) —
  discovered by testing the real API, which unblocked the whole update pipeline.
  `NSWindow.sendEvent` as the pre-toolbar funnel solved the toolbar right-click
  after `menu`/`rightMouseDown`/gestures all failed.
- **Prior art consulted before inventing.** `nodes-app/swift-markdown-engine`
  (ARCHITECTURE §14) solves the same TK2 live-preview problems with different
  trade-offs — a comparison point and technique source. MarkEdit/CotEditor as
  product references (ROADMAP).
- **Field reports with logs + movs.** `misc/bug-repros/` holds the maintainer's
  screen recordings and trace logs — the round-4 drag-move mechanism came
  straight out of one such trace.

---

## 6. Anti-patterns (each with its historical cost)

| Anti-pattern | Cost paid |
|---|---|
| Fix at symptom time | Patches the wrong instant — symptom armed minutes earlier (round 6) |
| Trust headless green for a live-input bug | Round-6 test passes with *and* without the fix |
| Stack speculative fixes | Rounds 1–5 each "fixed" it; each came back |
| Skip document reconstruction | Geometry/block-kind-dependent bugs don't fire on `"hello world"` |
| Trust a possibly-stale binary | SwiftPM prints `Build complete!` without relinking → wrong conclusions |
| Declare victory without a soak | One clean repro misses armed-state / degradation bugs |

---

## When NOT to use this skill

- Actually running the caret investigation step by step →
  **edmund-caret-integrity-campaign**.
- The repro drivers and trace decoding → **edmund-live-repro-and-diagnostics**.
- What evidence a change type requires + the test suite → **edmund-validation-and-qa**.
- The settled history you're checking against → **edmund-failure-archaeology**.
- Picking the next big problem → **edmund-research-frontier**.

---

## Provenance and maintenance

Verified 2026-07-05.

```bash
grep -nE '^## Round|honest gaps|Verification limits' docs/delete-drift-investigation.md docs/viewport-glitch-investigation.md
grep -n '321\|290' docs/delete-drift-investigation.md         # the predicted numbers (§2)
grep -rn 'assertMatchesFullRecomposeOracle' Tests/EdmundTests/
ls misc/bug-repros/                                            # field-evidence seam (§5)
```

The methods are stable; the *episodes* they cite are the drift risk — if a new
round rewrites the delete-drift narrative, refresh the worked examples here.
