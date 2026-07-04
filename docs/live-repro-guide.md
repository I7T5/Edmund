# Producing real repros of live-app bugs

How to turn a "happens sometimes while typing" field report into a
deterministic, scriptable reproduction against the real app. Distilled from
the delete-drift investigation (`delete-drift-investigation.md`), where six
rounds of trace-reading became a one-command repro only after the techniques
below were assembled. Written for both humans and agents debugging Edmund.

**Why this exists:** a class of Edmund bugs lives in the live NSTextView /
TextKit 2 / input-context layer — deferred selection fixups, IME composition,
drag sessions, event-loop timing. Headless tests *cannot* form the broken
state (the test harness runs AppKit's deferred machinery synchronously), so a
green unit test proves nothing about this class. The delete-drift round-6
repro test passes with and without the fix; only the live scripted repro
distinguishes them.

---

## 1. The escalation ladder

Work down this list; stop at the first level that reproduces. Each level is
more faithful and more expensive than the one before.

| # | Technique | Faithful to | Cost | Use when |
|---|-----------|-------------|------|----------|
| 1 | Plain unit test (`makeEditor()`) | model/parsing/styling logic | seconds | anything not event-timing-dependent |
| 2 | Windowed unit test (NSWindow + NSScrollView, real `deleteBackward(nil)` etc.) | + layout, viewport, first-responder | seconds | viewport/lazy-styling bugs (see `LazyRenderingTests` for the setup) |
| 3 | **In-process ReproScript** (§3) | + real AppKit key path, real run-loop pacing, real app process | ~1 min/run | anything keyboard/edit-pipeline shaped; **the default for live bugs** |
| 4 | CGEvent driver (§5) | + real HID events, real mouse (drags!) | TCC-dependent | mouse-only paths: drag-select, drag-move, autoscroll |
| 5 | Manual repro by the user with verbose logs on | everything | days of latency | when you can't trigger it; instrument first (§2) so the *next* occurrence is decisive |

Two levels deserve emphasis:

- Level 2 failing to repro is *evidence*, not defeat — it tells you the bug
  needs deferred/queued AppKit state, which points you at level 3–4 and at
  event-ordering hypotheses.
- Level 3 exists because level 4 is unreliable: background/agent sessions
  often have no Accessibility/TCC grant, and synthetic keyboard events get
  silently dropped. In-process injection needs no permission at all.

## 2. Step 0 — make the trace tell you the trigger

Never start scripting blind. The repro recipe is almost always already in
`~/.edmund/logs`, if verbose diagnostics were on:

```bash
# launch flags (defaults keys are namespaced; file arg MUST be argv[1]):
<app>/Contents/MacOS/edmd FILE.md \
  -settings.general.diagnosticLogging YES \
  -settings.advanced.verboseEditorDiagnostics YES
```

What to look for (all from `EditorTextView+Diagnostics.swift`):

- Every trace line carries `sel/active/marked/up/undo/blocks/storLen/rawLen`.
  `up=Y` = the event arrived while `isUpdating` (mid-recompose).
- **Healthy edit ordering**: `shouldChangeText` → `selectionDidChange` (up=N)
  → `synced`. A transient `⚠︎LEN-MISMATCH` *between* those lines is normal
  (storage moves before rawSource syncs).
- **Suspect orderings**: a `selectionDidChange` with `up=Y` at a surprising
  position; a persisting LEN-MISMATCH; a `shouldChangeText` with **no**
  `synced`/`SKIPPED`/`DEFERRED` line after it (a bypassed `didChangeText`);
  the `healing storage edit that bypassed didChangeText` breadcrumb.
- `traceSelectionOrigin` logs a **call stack** for any selection change that
  lands mid-recompose — this is what named
  `_fixSelectionAfterChangeInCharacterRange` in round 6. If your bug moves
  the caret and you don't know who moved it, this answers it in one run.
- **Walk backwards from the first bad line, not forwards from the symptom.**
  The round-6 drift at 22:13 was armed by a bypass at 22:11:57 — 80 seconds
  and dozens of healthy edits earlier. The user-visible failure is often the
  *second* half of a two-part mechanism.

If the existing logging didn't capture the deciding fact, **add the log line
first** and reproduce again — one cheap breadcrumb (a call stack, an internal
state dump) is worth ten speculative fixes. Keep the good ones behind
`Log.shouldTrace` and ship them; that's how the diagnostics accumulated.

Also reconstruct the *document*. Ask the user for the file (or rebuild it
from the trace's block counts/lengths). Wrapped-paragraph geometry, block
boundaries, and block kinds all matter; repro against a lookalike document,
not `"hello world"`.

## 3. The in-process repro driver (ReproScript)

`Sources/edmd/App/ReproScript.swift`, DEBUG builds only. The app replays a
keystroke script against the front document by synthesizing `NSEvent`s and
pushing them through `window.sendEvent(_:)` — the full authentic key route
(keyDown → `interpretKeyEvents` → `insertText:` / `deleteBackward:`). No
Accessibility permission, no visible window required (works with the window
on an inactive Space), real run-loop pacing between keystrokes.

```bash
build/EdmundDbg.app/Contents/MacOS/edmd "$DOC.md" \
  -settings.general.diagnosticLogging YES \
  -settings.advanced.verboseEditorDiagnostics YES \
  -debug.reproScript "$SCRIPT.repro" \
  -ApplePersistenceIgnoreState YES &
```

Script commands, one per line (`#` comments allowed):

| Command | Effect |
|---|---|
| `sleep <ms>` | wait before the next command |
| `caret <needle>` | place the caret before the first occurrence of `<needle>` |
| `type <text>` | one real key event per character, ~80 ms apart |
| `backspace <n>` | n real delete keystrokes, 300 ms apart |
| `bypassdelete <needle>` | simulate the drag-move source deletion: select the range, `shouldChangeText` + storage mutation, **no `didChangeText`** |
| `assertcaret <needle>` | log `repro assertcaret PASS/FAIL sel=… want=…` iff the caret sits exactly before `<needle>` |
| `logsel` | log the current selection, rawSource length, document count |

Round-6 minimal repro, for flavor:

```
sleep 2000
bypassdelete Sizemore, 
sleep 800
logsel            # broken build: {321,0}; fixed build: {290,0}
backspace 2
logsel
```

Design rules that made this work — keep them when extending:

- **Address text by needle, never by offset.** Offsets go stale the moment a
  script edits the document; needles survive, which is what makes multi-step
  soak scripts possible.
- **Real events over direct method calls** for the user-driven steps.
  `pressBackspace`-style `insertText("", …)` shortcuts skip
  `deleteBackward`'s selection machinery — the exact place round 6 lived.
- **Simulate AppKit-internal paths by exact call sequence.** `bypassdelete`
  replicates precisely what AppKit's drag-move does (`shouldChangeText` →
  `replaceCharacters`, no `didChangeText`) — not an approximation of its
  effect. If you're simulating some other internal path, first pin down its
  real call sequence from a `traceSelectionOrigin`-style stack, then replay
  that sequence verbatim.
- **Asserts inside the app, results in the log.** The harness (you, or a
  shell loop) only greps for `PASS`/`FAIL`; the app is the oracle.
- New commands are ~10 lines each in `ReproScript.swift`. Extend it rather
  than working around it.

## 4. Building and launching the debug app

- **Bundle fast path** (no `build-app.sh` needed): `build/EdmundDbg.app/
  Contents/` holds `Info.plist` (copy of the repo one) and `MacOS/` with the
  debug `edmd` plus `.build/arm64-apple-macosx/debug/Sparkle.framework`
  (dyld aborts without it). A bare `.build/debug/edmd` runs but never creates
  a window.
- **Launch by direct exec of the bundle binary**, not `open -a`.
  LaunchServices can silently run a stale cached/translocated copy of the
  bundle — you'll be executing last hour's code and drawing wrong
  conclusions. Direct exec runs exactly the binary you just copied.
- `-ApplePersistenceIgnoreState YES` — otherwise state restoration reopens
  previous (possibly mutated) documents and your script edits the wrong
  buffer.
- **Recreate the test document fresh before every run.** Autosave mutates it;
  run 2 of a script against run 1's leftovers produces garbage offsets.
- **Check for the user's live instance first**: `pgrep -lx edmd` + `ps -o
  lstart=,command= -p <pid>`. The user's daily-driver app has the same binary
  name. Never `pkill -x edmd`; kill only your own PID (`pkill -f EdmundDbg`
  works if you launched the debug bundle).
- **Verify the binary is fresh before trusting a run.** SwiftPM sometimes
  prints `Build complete!` having compiled but *not relinked* `edmd`. Grep
  `strings .build/arm64-apple-macosx/debug/edmd` for a long literal unique to
  your new code (≤15-byte literals are stored inline on arm64 and won't
  appear). Stale → `swift package clean`. Never hand-delete
  `.build/…/edmd.build/` — it corrupts the output-file-map.

## 5. CGEvent driver (mouse paths, TCC willing)

For paths that *must* originate as HID events — real drag-select, drag-move,
autoscroll — keyboard replay can't cover them. A ~70-line `ui.swift`
(compile with `swiftc`) posting `CGEvent`s does: `bounds <substr>` (window
lookup via `CGWindowListCopyWindowInfo`), `click x y`, `dragselect`,
`dragmove` (mousedown + **~400 ms hold** before moving, or AppKit never arms
the text drag), `key`, `type`. See the delete-drift doc for the round-4 use.

Caveats, all hit in practice:

- **TCC decides per session.** Background/agent sessions often can't post
  keyboard events (dropped silently) or use System Events (assistive access
  denied). Test with one click + log check; if input doesn't land, fall back
  to §3 immediately — don't iterate on driver variations.
- The app's windows are on an inactive Space until activated
  (`kCGWindowIsOnscreen == false`); `osascript -e 'tell application
  "<path>.app" to activate'` (Apple Events, separate TCC bucket) may work
  where System Events is denied.
- Re-activate before every interaction batch; focus is lost between shell
  invocations.

## 6. Soak scripts — accumulate a session

One-shot repros miss bugs that need *armed state* (round 6's queued fixup) or
degrade over time. After a fix, run a soak: a single script, one app run,
that chains several trigger cycles at different document positions with
ordinary editing (typing, backspaces, block-merging deletes) between them,
and an `assertcaret` after every step that has a predictable answer:

```
bypassdelete Sizemore, 
assertcaret Strang
backspace 2
type xy
bypassdelete widely 
assertcaret used in various
# … more cycles …
logsel
```

Grep the log for `FAIL`. A soak that stays green across 4–5 cycles is far
stronger evidence than one clean repro — and byte-identical final `rawLen`
across runs confirms the whole chain is deterministic.

## 7. The loop, end to end

1. Verbose trace from the field occurrence → find the first bad line, walk
   backwards, form a trigger hypothesis (§2).
2. Reconstruct the document; script the hypothesized trigger (§3).
3. No repro? The hypothesis is wrong or the fidelity level too low — move
   down the ladder (§1), or instrument and wait for the next field hit.
4. Repro in hand? **Freeze it** (exact script + document), then let it
   falsify fix candidates — round 6's first fix "worked" by reasoning and
   failed in the repro within a minute.
5. Fix verified → soak (§6) → full `swift test` → keep the script and the
   new diagnostics; update `delete-drift-investigation.md` (or the relevant
   investigation doc) with the mechanism and the repro recipe.

The meta-lesson from six rounds: **time spent making the failure cheap to
observe beats time spent reasoning about the fix.** Every round that shipped
on reasoning alone came back; the round that shipped on a deterministic
repro named the actual mechanism.
