---
name: edmund-live-repro-and-diagnostics
description: >
  How to MEASURE Edmund instead of eyeballing it — the diagnostic tools,
  interpretation guides, and working scripts. Load when a bug involves LIVE
  behavior (caret, IME, drag, viewport timing), when a unit test cannot
  reproduce a report, when you need to read diagnostic traces, drive the
  running app with scripted keystrokes, or measure pixels from a screenshot.
  Contains the repro escalation ladder, the ReproScript driver, the CGEvent
  fallback, and screencapture measurement, plus scripts/ helpers. Not the
  symptom→mechanism table (edmund-debugging-playbook), not the campaign
  (edmund-caret-integrity-campaign), not build hygiene (edmund-build-and-env).
---

# Edmund live repro & diagnostics

A class of Edmund bugs lives in the live NSTextView / TextKit 2 / input-context
layer (deferred selection fixups, IME composition, drag sessions, event-loop
timing). **Headless tests cannot form the broken state** — the test harness runs
AppKit's deferred machinery synchronously, so a green unit test proves nothing
about this class. This skill is how you make such a bug cheap to observe, then
deterministic. Primary source doc: `docs/live-repro-guide.md`.

Verified 2026-07-05.

---

## 0. Safety preamble (do this every time)

- **Check for the user's live instance first.** The user's daily-driver app has
  the same binary name (`edmd`). Run `scripts/check-live-instance.sh`. **Never
  blanket `pkill -x edmd`** — kill only your own PID, or use `pkill -f
  EdmundDbg` (only your debug bundle matches).
- **Recreate the test document fresh before every run** — autosave mutates it;
  run 2 against run 1's leftovers produces garbage offsets.
- **Verify the binary is fresh** before trusting a run (SwiftPM sometimes prints
  `Build complete!` without relinking `edmd`) — strings/shasum method in
  **edmund-build-and-env**.
- **Do not request macOS Computer Access.** Screen Recording + Accessibility are
  already granted for this project; ReproScript (§3) needs neither.

---

## 1. The escalation ladder

Work down; stop at the first level that reproduces. Each is more faithful and
more expensive than the one above.

| # | Technique | Faithful to | Cost | Use when |
|---|---|---|---|---|
| 1 | Plain unit test (`makeEditor()`) | model/parse/style logic | seconds | anything not event-timing-dependent |
| 2 | Windowed unit test (NSWindow + NSScrollView, real `deleteBackward(nil)`) | + layout, viewport, first responder | seconds | viewport/lazy-styling bugs (`LazyRenderingTests` setup) |
| 3 | **In-process ReproScript** (§3) | + real key path, run-loop pacing, real process | ~1 min/run | anything keyboard/edit-pipeline shaped — **the default for live bugs** |
| 4 | CGEvent driver (§4) | + real HID events, real mouse (drags!) | TCC-dependent | mouse-only paths: drag-select, drag-move, autoscroll |
| 5 | Instrumented field occurrence | everything | days | can't trigger it — instrument first (§2), decide on the next hit |

Two levels deserve emphasis:
- **Level 2 failing to repro is evidence, not defeat** — it tells you the bug
  needs deferred/queued AppKit state, pointing you at level 3–4.
- **Level 3 exists because level 4 is unreliable** — background/agent sessions
  often have no TCC grant and synthetic keyboard events get dropped silently.
  In-process injection needs no permission.

---

## 2. Step 0 — make the trace tell you the trigger

Never script blind. The recipe is usually already in `~/.edmund/logs`, if
verbose diagnostics were on. Launch flags (file arg **must** be `argv[1]`):

```bash
<app>/Contents/MacOS/edmd FILE.md \
  -settings.general.diagnosticLogging YES \
  -settings.advanced.verboseEditorDiagnostics YES
```

**Trace-field decoder** (each verbose line carries these; from
`EditorTextView+Diagnostics.swift`):

| Field | Meaning |
|---|---|
| `sel` | current selection `{location,length}` |
| `active` | active (caret) block index |
| `marked` | is there marked/IME text |
| `up` | `isUpdating` — **`up=Y` = event arrived mid-recompose** (suspicious) |
| `undo` | undo-stack depth |
| `blocks` | block count |
| `storLen` / `rawLen` | storage length vs rawSource length |

- **Healthy edit ordering:** `shouldChangeText` → `selectionDidChange` (up=N) →
  `synced`. A transient `⚠︎LEN-MISMATCH` *between* those lines is normal
  (storage moves before rawSource syncs).
- **Suspect:** a `selectionDidChange` with `up=Y` at a surprising position; a
  **persisting** LEN-MISMATCH; a `shouldChangeText` with **no**
  `synced`/`SKIPPED`/`DEFERRED` after it (a bypassed `didChangeText`); the
  `healing storage edit that bypassed didChangeText` breadcrumb.
- **`traceSelectionOrigin`** logs a **call stack** for any selection change that
  lands mid-recompose — this is what named `_fixSelectionAfterChange` in round 6.
- **Walk BACKWARDS from the first bad line, not forwards from the symptom.** The
  round-6 drift was armed ~80 seconds and dozens of healthy edits before the
  visible failure. The user-visible symptom is often the *second* half.

If the log didn't capture the deciding fact, **add the log line first** (keep
good ones behind `Log.shouldTrace` and ship them) and reproduce again. Also
**reconstruct the document** — wrapped-paragraph geometry, block boundaries, and
block kinds all matter; repro against a lookalike, never `"hello world"`.

`scripts/grep-trace.sh [YYYY-MM-DD]` surfaces the suspect patterns in one shot.

---

## 3. The in-process ReproScript driver (default for live bugs)

`Sources/edmd/App/ReproScript.swift`, **DEBUG builds only**. Replays a keystroke
script against the front document by synthesizing `NSEvent`s and pushing them
through `window.sendEvent(_:)` — the full authentic key route (keyDown →
`interpretKeyEvents` → `insertText:` / `deleteBackward:`). No Accessibility, no
visible window required (works on an inactive Space), real run-loop pacing.

Launch: `scripts/launch-debug.sh FILE.md SCRIPT.repro` (assembles EdmundDbg.app,
guards the user's instance, direct-execs with all flags). Or by hand:

```bash
build/EdmundDbg.app/Contents/MacOS/edmd "$DOC.md" \
  -settings.general.diagnosticLogging YES \
  -settings.advanced.verboseEditorDiagnostics YES \
  -debug.reproScript "$SCRIPT.repro" \
  -ApplePersistenceIgnoreState YES &
```

**Command surface** (one per line, `#` comments allowed):

| Command | Effect |
|---|---|
| `sleep <ms>` | wait before the next command |
| `caret <needle>` | place caret before the first occurrence of `<needle>` |
| `type <text>` | one real key event per char, ~80 ms apart |
| `backspace <n>` | n real delete keystrokes, ~300 ms apart |
| `bypassdelete <needle>` | simulate the drag-move source deletion: select range, `shouldChangeText` + storage mutation, **no `didChangeText`** |
| `assertcaret <needle>` | log `repro assertcaret PASS/FAIL sel=… want=…` iff caret sits exactly before `<needle>` |
| `logsel` | log selection, rawSource length, doc count |

Round-6 minimal repro (the worked example): the deciding output was **`logsel`
321 (broken) → 290 (fixed)**, every run, window not even visible.

```
sleep 2000
bypassdelete Sizemore,
sleep 800
logsel            # broken: {321,…}; fixed: {290,…}
backspace 2
logsel
```

**Design rules — keep them when extending:**
- **Address text by needle, never offset** — offsets go stale the moment a
  script edits; needles survive (this is what makes soak scripts possible).
- **Real events over direct method calls** — `insertText("")` shortcuts skip
  `deleteBackward`'s selection machinery, the exact place round 6 lived.
- **Simulate AppKit-internal paths by exact call sequence** — `bypassdelete`
  replicates `shouldChangeText` → `replaceCharacters`, no `didChangeText`
  *verbatim*, not an approximation. Pin any new internal path's real sequence
  from a `traceSelectionOrigin` stack first, then replay it.
- **Asserts inside the app, results in the log** — the harness (you, or a shell
  loop) only greps `PASS`/`FAIL`; the app is the oracle.
- New commands are ~10 lines each — extend `ReproScript.swift`, don't work around it.

**Soak scripts** (§6): chain several trigger cycles at different positions with
ordinary editing between them, `assertcaret` after each predictable step, and
compare final `rawLen` across runs (byte-identical = deterministic). A soak green
across 4–5 cycles is far stronger than one clean repro — it catches bugs needing
*armed state* (round 6's queued fixup).

```
bypassdelete Sizemore,
assertcaret Strang
backspace 2
type xy
bypassdelete widely
assertcaret used in various
logsel
```

---

## 4. CGEvent driver (mouse-only paths, TCC willing)

For paths that must originate as HID events — real drag-select, drag-move,
autoscroll — keyboard replay can't cover them. A ~70-line `ui.swift` (compile
with `swiftc`) posting `CGEvent`s does: `bounds <substr>` (window lookup via
`CGWindowListCopyWindowInfo`), `click x y`, `dragselect`, `dragmove` (mousedown +
**~400 ms hold** before moving, or AppKit never arms the text drag), `key`,
`type`.

Caveats (all hit in practice):
- **TCC decides per session.** Background/agent sessions often can't post
  keyboard events (dropped silently) or use System Events. Test with **one click
  + log check**; if input doesn't land, fall back to §3 immediately — don't
  iterate on driver variations.
- App windows are on an inactive Space until activated
  (`kCGWindowIsOnscreen == false`); `osascript -e 'tell application "<path>.app"
  to activate'` (Apple Events, a separate TCC bucket) may work where System
  Events is denied.
- Re-activate before every interaction batch; focus is lost between shell calls.

---

## 5. Screencapture measurement

**Visual judgments are measured, not eyeballed** — when the task says "balance
padding" or "align the icon", capture the window and measure pixels.

`scripts/capture-window.sh <window-title-substring> out.png` finds the window id
(JXA → `CGWindowListCopyWindowInfo`) and runs `screencapture -x -o -l<id>`.
Notes:
- Capture **by window id**, reliable even when not frontmost.
- **Crop by the detected window bounds** — the desktop wallpaper defeats
  screencapture's brightness-based auto-crop.
- Measure padding/alignment from the PNG (e.g. a short Python/PIL pixel scan for
  the first/last colored row of a callout box). Report the pixel numbers, not an
  impression.
- Window-server state can glitch (tiny windows, restoration) after many rapid
  launch/kill cycles: `rm -rf ~/Library/"Saved Application State"/com.i7t5.edmund.savedState`
  and relaunch.

---

## 6. The loop, end to end

1. Verbose trace from the occurrence → find the **first bad line**, walk
   backwards, form a trigger hypothesis (§2).
2. Reconstruct the document; script the hypothesized trigger (§3).
3. **No repro?** Hypothesis wrong or fidelity too low — move down the ladder
   (§1), or instrument and wait for the next hit.
4. **Repro in hand? Freeze it** (exact script + document), then let it falsify
   fix candidates — round 6's first "fix by reasoning" failed in the repro within
   a minute.
5. Fix verified → **soak** (§3) → full `swift test` → keep the script + new
   diagnostics → update the relevant `docs/*-investigation.md`.

**Meta-lesson from six rounds: time spent making the failure cheap to observe
beats time spent reasoning about the fix.** Every round that shipped on reasoning
alone came back; the round that shipped on a deterministic repro named the actual
mechanism.

---

## scripts/ (in this skill dir)

| Script | Purpose | Status |
|---|---|---|
| `check-live-instance.sh` | Report running `edmd`, exit 2 if any; never kills | logic verified; safe by construction |
| `grep-trace.sh [date]` | Surface suspect patterns in today's log | logic verified |
| `capture-window.sh <needle> <out.png>` | Screenshot a window by id + report bounds | **verify on first use** (JXA CGWindowList lookup not executed this session) |
| `launch-debug.sh <file.md> [script.repro]` | Build + assemble EdmundDbg.app + direct-exec with flags | **verify on first use** (assumes arm64 debug triple; guards user instance) |

All four pass `bash -n`. The two "verify on first use" scripts depend on live
system state (window server, build layout) that couldn't be exercised while
authoring; read the header comment before first run.

---

## When NOT to use this skill

- Deciding *which mechanism* a symptom implies → **edmund-debugging-playbook**.
- Running the full caret-integrity investigation → **edmund-caret-integrity-campaign**.
- Stale-binary detection / bundle internals → **edmund-build-and-env**.
- What counts as sufficient evidence to ship → **edmund-validation-and-qa**.
- The AppKit theory behind the fixup/marked-text mechanisms → **textkit2-appkit-reference**.

---

## Provenance and maintenance

Verified 2026-07-05 against `docs/live-repro-guide.md`,
`Sources/edmd/App/ReproScript.swift`, and
`Sources/EdmundCore/TextView/EditorTextView+Diagnostics.swift`.

```bash
grep -oiE '"(sleep|caret|type|backspace|bypassdelete|assertcaret|logsel)"' Sources/edmd/App/ReproScript.swift | sort -u
grep -n 'debug.reproScript' Sources/edmd/App/ReproScript.swift
grep -rn 'traceSelectionOrigin\|LEN-MISMATCH\|shouldTrace' Sources/EdmundCore/TextView/EditorTextView+Diagnostics.swift Sources/EdmundCore/Diagnostics/Log.swift
grep -n 'healing storage edit' Sources/EdmundCore/TextView/EditorTextView+EditFlow.swift
```

Re-verify the scripts against `docs/live-repro-guide.md` §4 if the debug-bundle
assembly recipe changes.
