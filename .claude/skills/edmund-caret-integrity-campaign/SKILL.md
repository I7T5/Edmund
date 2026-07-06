---
name: edmund-caret-integrity-campaign
description: >
  The executable, decision-gated campaign for Edmund's hardest live problem:
  the delete-drift class (caret/selection integrity in the live NSTextView /
  TextKit 2 / input-context layer). Load when the caret or selection lands in
  the wrong place after a delete/type/IME/drag interaction, when text edits
  corrupt or desync, when autosave writes stale content, or when logs show
  ⚠︎LEN-MISMATCH or the "healing storage edit that bypassed didChangeText"
  breadcrumb. Runs round 7+ at the retiring maintainer's standard: classify,
  fence off six settled battles, capture evidence, build a deterministic repro,
  pick from a ranked solution menu with proof obligations, then validate and
  promote through change control. Not for viewport/scroll drift (that's
  edmund-debugging-playbook → viewport docs) unless the caret itself moves.
---

# Caret-integrity campaign (the delete-drift class)

Six rounds are settled; **new rounds are expected**. This class does **not
reproduce in headless tests** — the harness runs AppKit's deferred machinery
synchronously, so a green unit test proves nothing here. Success is measured by
`PASS/FAIL` grep and byte counts, **never by eye or by reasoning**.

Verified 2026-07-05 against `docs/delete-drift-investigation.md` (456 lines) and
the code. Read that doc fully before a deep dive.

---

## QUICK CARD (the whole loop)

```
0. CLASSIFY   grep logs for the 4 signatures. Not this class? → debugging-playbook.
1. FENCE      check the 6 settled battles + guards still hold. Don't re-fight them.
2. EVIDENCE   run with verbose diags; find FIRST bad line; walk BACKWARDS;
              traceSelectionOrigin names who moved the caret; rebuild the doc.
3. REPRO      ReproScript: needles not offsets; real events; replicate internal
              call sequences verbatim. Freeze a script whose logsel/assertcaret
              DISCRIMINATES broken vs current build. No repro → hypothesis wrong.
4. SOLVE      rank candidates (missing guard < extend heal < reorder fixup <
              structural). Each states what it must PROVE.
5. PROMOTE    fix flips frozen repro to PASS same run → soak 4–5 cycles,
              byte-identical rawLen → swift test green → add test (locks headless
              contract even if non-discriminating) + keep .repro → update the
              investigation doc → branch/commit via change-control. Never ship on
              reasoning alone.
```

---

## PHASE 0 — Classify: is it actually this class?

Grep `~/.edmund/logs/edmund-<date>.log` (run the app with
`-settings.general.diagnosticLogging YES -settings.advanced.verboseEditorDiagnostics YES`):

| Signature | Meaning |
|---|---|
| `healing storage edit that bypassed didChangeText` | a bypass fired (round-4 class) |
| **persisting** `⚠︎LEN-MISMATCH` (not just transient between shouldChangeText→synced) | storage/rawSource desync stuck |
| `selectionDidChange` with `up=Y` at a surprising position | selection moved mid-recompose (round-6 class) |
| a `shouldChangeText` with **no** `synced`/`SKIPPED`/`DEFERRED` after it | a bypassed `didChangeText` |

`scripts/grep-trace.sh` in **edmund-live-repro-and-diagnostics** surfaces all
four at once.

**If none match and the symptom is scroll/viewport-shaped** (jump, wrong
landing, can't-scroll-up) with the caret *not* leaping → this is the viewport
class, not caret integrity → **edmund-debugging-playbook** +
`docs/viewport-glitch-investigation.md`. Do not run this campaign on a viewport
bug.

---

## PHASE 1 — Fence off the six settled battles

Confirm each shipped guard **still holds** before hypothesizing a new mechanism.
The most likely round-7 shape is a **new code path that lacks an existing
guard**, not a new mechanism.

| Round | Mechanism (settled) | The shipped guard — confirm it still covers your path |
|---|---|---|
| 1–3 | IME **marked-text stranding**: styling that runs `beginEditing`/`setAttributes`/`invalidateLayout` while `hasMarkedText()` strands the composition; `didChangeText` then bails forever and every edit drifts | **every storage-touching styling path guards `!hasMarkedText()`** — including async ones scheduled *before* composition began (`+SelectionTracking` caret-move restyle). `becomeFirstResponder` resyncs as catch-all |
| 4 | **Drag-move bypass**: a drag-move whose drop has no valid target deletes via `shouldChangeText`→`replaceCharacters` with **no `didChangeText`**; `rawSource`/`blocks` freeze; autosave writes stale text | `scheduleBypassedEditSyncCheck` (`+EditFlow.swift`): a next-run-loop check finds an unconsumed storage `pendingEdit` and runs the sync (breadcrumb above) |
| 5 | **Heal leaped the caret**: the round-4 heal ran against a **stale** selection and moved the caret | heal collapses/derives the caret from the `pendingEdit` hull before syncing |
| 6 | **Queued selection fixup**: TK2's `_fixSelectionAfterChangeInCharacterRange` stays queued after a bypass and fires at the **next `endEditing`** (even an attribute-only restyle), remapping the **stale** selection and leaping even a *freshly set, valid* caret | heal sets the caret from the pendingEdit hull **before** the sync **AND re-asserts it after** (`+EditFlow.swift`) |

Confirm the guards exist:
```bash
grep -rn 'hasMarkedText' Sources/EdmundCore/TextView/
grep -n 'scheduleBypassedEditSyncCheck\|healing storage edit' Sources/EdmundCore/TextView/EditorTextView+EditFlow.swift
```

### FENCED WRONG PATHS (each proven dead — do not retry)

- **Fixing by nudging the caret at symptom time.** The symptom is armed
  seconds-to-minutes *earlier* (round 6: drift at 22:13 armed at 22:11:57). You'd
  patch the wrong instant.
- **Trusting a headless regression test.** The round-6 test passes **with and
  without** the fix. Headless runs the fixup synchronously.
- **Shipping on reasoning alone.** Rounds 1–5 all came back. Round 6's first fix
  candidate "worked by reasoning" and **failed in the repro within a minute**.
- **Assuming `didChangeText` pairs with every mutation.** AppKit violates this
  (round 4).
- **Mutating storage mid-composition.** That is the original bug (rounds 1–3).

---

## PHASE 2 — Capture evidence

1. Launch with verbose diagnostics (debug bundle; file arg is `argv[1]`):
   ```bash
   build/EdmundDbg.app/Contents/MacOS/edmd DOC.md \
     -settings.general.diagnosticLogging YES \
     -settings.advanced.verboseEditorDiagnostics YES \
     -ApplePersistenceIgnoreState YES
   ```
2. **Decode the trace fields:** `sel/active/marked/up/undo/blocks/storLen/rawLen`.
   `up=Y` = event arrived mid-recompose (suspicious). Healthy ordering:
   `shouldChangeText` → `selectionDidChange (up=N)` → `synced`; a transient
   `⚠︎LEN-MISMATCH` between those is normal, a persisting one is not.
3. **Find the FIRST bad line, then walk BACKWARDS.** The visible symptom is often
   the second half of a two-part mechanism.
4. **`traceSelectionOrigin`** logs the call stack of whoever moved the selection
   mid-recompose — this is what named `_fixSelectionAfterChange` in round 6. If
   the caret moves and you don't know who moved it, this answers it in one run.
5. **Reconstruct the document.** Wrapped-paragraph geometry and block kinds
   matter — repro against a lookalike, never `"hello world"`.

**Gate:** you have a candidate trigger hypothesis + the first-bad-line timestamp.
Otherwise **instrument** (add a `Log.shouldTrace` breadcrumb — one call stack or
state dump beats ten speculative fixes) and wait for the next occurrence.

---

## PHASE 3 — Build the deterministic repro

Use the in-process **ReproScript** driver (`Sources/edmd/App/ReproScript.swift`,
DEBUG only; full guide in edmund-live-repro-and-diagnostics). Commands:
`sleep / caret / type / backspace / bypassdelete / assertcaret / logsel`.

**Worked example — the round-6 minimal repro** (the first deterministic repro in
six rounds):
```
sleep 2000
bypassdelete Sizemore,
sleep 800
logsel            # broken build: 321   fixed build: 290
backspace 2
logsel
```
The deciding output was `logsel` **321 → 290** with the fix, every run, window
not even visible.

Rules that make repros survive editing:
- **Needles, not offsets** — offsets go stale the instant the script edits.
- **Real events, not method shortcuts** — `insertText("")` skips
  `deleteBackward`'s selection machinery, exactly where round 6 lived.
- **Replicate AppKit-internal call sequences verbatim** — `bypassdelete` does
  `shouldChangeText`→`replaceCharacters`, no `didChangeText`, not an
  approximation. For a *new* internal path, pin its real sequence from a
  `traceSelectionOrigin` stack first, then replay it (extend ReproScript ~10
  lines).

**Gate:** a **frozen** script (exact commands + document) whose `logsel` /
`assertcaret PASS/FAIL` output **discriminates** the broken build from the
current one.

**No repro after honest attempts?** The hypothesis is wrong, or fidelity is too
low — a mouse-only path (real drag-select/drag-move) needs the **CGEvent driver**
(edmund-live-repro-and-diagnostics §4). Loop back to Phase 2.

---

## PHASE 4 — Solution menu (ranked; each with a proof obligation)

Pick by the observation pattern. Cheaper is higher.

1. **Add a missing guard on an existing invariant** (cheapest, most likely for a
   new round). Guard inventory: `!hasMarkedText()` on the offending styling path;
   bypass-check scheduling on a new mutation entry point; caret re-assertion
   after a restyle. *Proof:* the frozen repro flips to PASS **and** no other
   `.repro` regresses. *Selects when:* a specific new code path shows the
   round-1/4/6 signature that its siblings already guard.
2. **Extend the heal to a new bypass source.** *Proof:* first add a ReproScript
   command that replays the new source's **exact** call sequence, show it
   reproduces the freeze, then show the extended heal fixes it. *Selects when:*
   trace shows a `shouldChangeText` with no close-out from a path other than
   drag-move.
3. **Intercept/reorder the queued fixup.** *Proof obligation:* explain **when**
   TK2 queues and fires `_fixSelectionAfterChange` and show the reorder does not
   fight AppKit's machinery (no oscillation, no double-move). *Selects when:*
   `traceSelectionOrigin` names the fixup and the caret is valid before it fires.
   Higher risk — you are stepping into private AppKit ordering.
4. **Structural: make rawSource sync independent of `didChangeText` pairing**
   (e.g. a storage-version counter that reconciles regardless of which callbacks
   fired). Biggest change; **candidate, unproven** — route through
   **edmund-research-frontier** (frontier item "caret integrity by
   construction"). *Proof:* all historical `.repro` scripts + a randomized
   bypass-fuzzer soak stay green with the callback-pairing assumption removed.

---

## PHASE 5 — Validate and promote

1. Fix candidate **flips the frozen repro to PASS within the same run**. (If it
   only "works by reasoning," it is not done — round history.)
2. **Soak** (edmund-live-repro-and-diagnostics §3): one script, one run, 4–5
   trigger cycles at different document positions with ordinary editing between,
   `assertcaret` after every predictable step. Green across all cycles **and
   byte-identical final `rawLen` across repeated runs** = deterministic.
3. **`swift test` green** (also the Stop hook).
4. **Add a regression test even if it can't discriminate the live mechanism** —
   it locks the headless contract (assert `rawSource == string`; see the
   `BypassedEditSyncTests` / `MarkedTextDesyncTests` family). **Keep the `.repro`
   script** in the repo for the live half.
5. **Update `docs/delete-drift-investigation.md`** with the new round (symptom →
   root cause → repro recipe → fix → status), and `docs/ARCHITECTURE.md` §8 if an
   invariant changed — **same PR**.
6. Route through **edmund-change-control**: branch `fix/…` off `main`, small
   commits, **never auto-push/PR/merge**. (No screencapture unless the fix also
   draws.)

**Never promote a fix that only "works by reasoning."**

---

## When NOT to use this skill

- Viewport/scroll drift where the caret itself does not leap →
  **edmund-debugging-playbook** + `docs/viewport-glitch-investigation.md`.
- Just need the repro driver mechanics / trace decoding →
  **edmund-live-repro-and-diagnostics**.
- The AppKit theory behind the mechanisms → **textkit2-appkit-reference**.
- The historical record of prior rounds → **edmund-failure-archaeology**.
- The structural (round-∞) redesign as a research project →
  **edmund-research-frontier** + **edmund-research-methodology**.

---

## Provenance and maintenance

Verified 2026-07-05 against `docs/delete-drift-investigation.md`,
`Sources/edmd/App/ReproScript.swift`, and
`Sources/EdmundCore/TextView/EditorTextView+EditFlow.swift`.

```bash
grep -nE '^## Round' docs/delete-drift-investigation.md          # round chronicle
grep -n 'scheduleBypassedEditSyncCheck\|healing storage edit' Sources/EdmundCore/TextView/EditorTextView+EditFlow.swift
grep -rn 'hasMarkedText' Sources/EdmundCore/TextView/
grep -oiE '"(bypassdelete|assertcaret|logsel)"' Sources/edmd/App/ReproScript.swift | sort -u
# round-6 discriminating numbers (321 broken / 290 fixed):
grep -n '321\|290' docs/delete-drift-investigation.md
```

When round 7 lands, add its row to Phase 1 and its dead ends to the fenced list.
