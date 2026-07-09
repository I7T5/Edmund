---
name: edmund-config-and-flags
description: >
  Catalog of every configuration axis in the Edmund Markdown editor — user
  settings (UserDefaults keys, defaults, where consumed), launch arguments
  (diagnostic + repro flags), compile-time gates, and logging config. Load
  when adding or changing a setting, hunting which flag controls a behavior,
  launching the app with debug flags, auditing defaults, or wiring a new
  preference into the live editor. This skill drifts fastest of the set —
  every table ends with a re-verification grep. Not for the invariants
  (see edmund-architecture-contract), release flags (edmund-release-and-operate),
  or how to READ the logs (edmund-live-repro-and-diagnostics).
---

# Edmund configuration & flags

Ground-truth catalog of every knob. **Code wins over docs** — every value
below was read from source on 2026-07-05; re-verify with the greps at the end
before trusting a value in a decision.

Two source-of-truth files:
- `Sources/edmd/Settings/AppSettings.swift` — every UserDefaults key + typed accessor.
- `Sources/edmd/Settings/*View.swift` (Appearance / General / Advanced) + `FontSettings` — the SwiftUI panes (`@AppStorage`).

Definitions used below: **UserDefaults** = macOS per-app persisted key/value store; **argument domain** = passing `-<key> <value>` on the command line overrides that default for one launch; **`@AppStorage`** = SwiftUI wrapper binding a view to a UserDefaults key.

---

## 1. User settings (UserDefaults keys)

Every key is a `static let` in `AppSettings.swift`. The key **string** (not the
Swift name) is what you pass as a launch arg.

| Swift name | Key string | Purpose |
|---|---|---|
| `reopenWindows` | `settings.general.reopenWindows` | Reopen last windows on launch |
| `startupAction` | `settings.general.startupAction` | What to do at startup (new doc / reopen / nothing) |
| `autoSaveWithVersions` | `settings.general.autoSaveWithVersions` | NSDocument autosave-in-place vs versions |
| `conflictResolution` | `settings.general.conflictResolution` | File-changed-on-disk handling |
| `suppressInconsistentLineEndingWarning` | `settings.general.suppressInconsistentLineEndingWarning` | Silence mixed-line-ending warning |
| `diagnosticLogging` | `settings.general.diagnosticLogging` | **On/off for file logging** (opt-out; see §4) |
| `logRetention` | `settings.general.logRetention` | Days of logs to keep (pruned on configure) |
| `appearanceMode` | `settings.appearance.mode` | Light / dark / system |
| `maxContentWidthCm` | `settings.appearance.maxContentWidthCm` | **Max column width, stored in CENTIMETRES** (see note) |
| `contentWidthUnit` | `settings.appearance.contentWidthUnit` | Display unit only (cm/in); the stored value is always cm |
| `renderBlankLinesAsBreaks` | `settings.reading.renderBlankLinesAsBreaks` | Read-mode blank-line handling |
| `sourceMode` | `settings.view.sourceMode` | When on, **Source replaces Edit** in the ⌘E toggle; honored on open |
| `verboseEditorDiagnostics` | `settings.advanced.verboseEditorDiagnostics` | **Verbose editor trace** (see §4; pairs with diagnosticLogging) |
| `sendCrashLogs` | `settings.advanced.sendCrashLogs` | Opt-in crash upload — **currently INERT** (see note) |
| `sentCrashReports` | `settings.advanced.sentCrashReports` | Dedup set of already-uploaded `.ips` filenames |
| `lastWindowHeight` | `settings.window.lastHeight` | Persisted window sizing (see the frame-not-content trap) |
| `automaticallyChecksForUpdates` | `SUAutomaticallyChecksForUpdates` | Sparkle's own key (not namespaced) |

**Content width (the physical-column design):** persisted as **centimetres**
(`maxContentWidthCm`); `contentWidthUnit` is a display unit only. The column is
an **absolute physical** cap converted to points via the display's real PPI
(`NSScreen.physicalPPI`, from `CGDisplayScreenSize`), applied as a symmetric
`textContainerInset.width`. Default is locale-aware — **5 in (US) / 12 cm
(elsewhere)** — and doubles as the slider's magnetic snap point. Recomputed on
resize and on `NSWindow.didChangeScreenNotification`. Consumer path lives in
`EditorTextView+ContentWidth.swift`.

**Window sizing trap:** persistence must round-trip the **frame** size, not the
`contentView.bounds` size — reapplying content size grows the window by the
title-bar + toolbar height on every reopen, and heights below `minSize` get
silently rejected. Save `window.frame.size`, reapply with `window.setFrame(_:)`
**after the toolbar is installed**. (Note: the key on disk is
`settings.window.lastHeight` — code, not the `lastWindowSize` some docs say.)

**Crash uploading is inert:** `sendCrashLogs` defaults off AND the Settings ▸
Advanced toggle is **commented out** in `AdvancedSettingsView.swift`, and
`CrashReporter.reportingEndpoint` is a `REPLACE-ME.invalid` placeholder
(`CrashReporter.swift:27`, `// TODO: real server`). Nothing uploads today.
Un-inert it only when a receiving server exists (see edmund-release-and-operate).

---

## 2. Launch arguments

macOS reads `-<UserDefaults-key> <value>` into the argument domain. Pass the
**key string** from §1, not the Swift name. The **file to open must be
`argv[1]`** (before the flags).

```bash
build/EdmundDbg.app/Contents/MacOS/edmd FILE.md \
  -settings.general.diagnosticLogging YES \
  -settings.advanced.verboseEditorDiagnostics YES \
  -debug.reproScript SCRIPT.repro \
  -ApplePersistenceIgnoreState YES
```

| Flag | Effect |
|---|---|
| `-settings.general.diagnosticLogging YES` | Turn on file logging for this run |
| `-settings.advanced.verboseEditorDiagnostics YES` | Emit the verbose editor trace (sel/active/marked/up/…) |
| `-debug.reproScript <path>` | **DEBUG builds only** — replay a keystroke script (`ReproScript.swift`) |
| `-ApplePersistenceIgnoreState YES` | Apple's flag — stop state restoration reopening mutated docs |

`-debug.reproScript` is the only Edmund-specific *debug* key; it does not have
an `AppSettings` accessor — it is read directly in `ReproScript.swift`. It is
compiled out of release builds.

---

## 3. Compile-time axes

`#if DEBUG` gates live in: `EditorTextView.swift`, `EditorTextView+EditFlow.swift`,
`Diagnostics/Log.swift`, `edmd/App/main.swift`, `edmd/App/ReproScript.swift`.
What they gate:

- **The TextKit-1 tripwire** (`EditorTextView.swift:273`+): a DEBUG observer on
  `NSTextView.willSwitchToNSLayoutManagerNotification` that asserts if the view
  ever falls back to TextKit 1. Ships only in DEBUG; the fallback itself is
  silent and permanent (see edmund-architecture-contract).
- **ReproScript** — the whole in-process keystroke driver.
- **Log level threshold** — `Log.swift` compiles a lower floor in DEBUG
  (`debug`+) than release (`info`+); see §4.

Named tuning constants (not user-facing, but they behave like knobs):

| Constant | Value | Where | Meaning |
|---|---|---|---|
| `fullLayoutMaxLength` | `100_000` | `EditorTextView.swift:80` | Docs ≤ this many UTF-16 units are kept **fully laid out** (below the TK2 estimate regime). Consumed at `+LazyStyling.swift:133`. |

---

## 4. Logging config

Read `Sources/EdmundCore/Diagnostics/Log.swift` and
`EditorTextView+Diagnostics.swift`.

- API: `Log.{debug,info,error}(_:category:)`, `Log.measure(_:) { … }`.
- File: `~/.edmund/logs/edmund-YYYY-MM-DD.log`, written on a private serial queue.
- Config flow: `AppSettings.applyLogging()` pushes the toggle + retention into
  `Log.configure` at launch and on change; retention pruning happens there.
- **Two independent switches**: `diagnosticLogging` (writes anything at all) and
  `verboseEditorDiagnostics` (adds the per-event editor trace). For a live
  repro you almost always want **both** on. Verbose lines are gated behind
  `Log.shouldTrace`.
- The log is **opt-out** (on by default), retention-pruned; the user only
  toggles it and picks a retention window in Settings ▸ General ▸ Diagnostics.

Trace-field decoding (`sel/active/marked/up/undo/blocks/storLen/rawLen`,
`⚠︎LEN-MISMATCH`, `traceSelectionOrigin`) is covered in
**edmund-live-repro-and-diagnostics** and **edmund-debugging-playbook** — one
home per fact; this skill only says which flags turn the trace on.

---

## 5. ReproScript command surface

`Sources/edmd/App/ReproScript.swift`, DEBUG only. One command per line, `#`
comments allowed.

| Command | Effect |
|---|---|
| `sleep <ms>` | wait before next command |
| `caret <needle>` | place caret before first occurrence of `<needle>` |
| `type <text>` | one real key event per char (~80 ms apart) |
| `backspace <n>` | n real delete keystrokes (~300 ms apart) |
| `bypassdelete <needle>` | simulate drag-move source deletion: `shouldChangeText` + storage mutation, **no `didChangeText`** |
| `assertcaret <needle>` | log `PASS/FAIL` iff caret sits exactly before `<needle>` |
| `logsel` | log selection, rawSource length, doc count |

Adding a command is ~10 lines in `ReproScript.swift`. Usage, soak patterns, and
launch recipe: **edmund-live-repro-and-diagnostics**.

---

## 6. How to ADD a setting (checklist)

Worked from an existing real path (`sourceMode` / content width). To add a
user-facing setting:

1. Add a `static let` key + typed accessor in `AppSettings.swift` (namespace the
   key string: `settings.<area>.<name>`).
2. Bind it in the relevant SwiftUI pane with `@AppStorage(AppSettings.<key>)`.
3. If it must affect **open documents live**, add/extend an `applyTo…` broadcast
   (see the font/line-height/content-width `applyTo…` helpers) so every open
   `Document.editor` picks it up — a setting that only takes effect on next open
   is usually a bug.
4. Pick a sane default (register it, or make the accessor default when absent).
5. New behavior needs a test + (if it draws) a screencapture check — route
   through **edmund-change-control** and **edmund-validation-and-qa**.

---

## When NOT to use this skill

- Understanding *why* an invariant exists → **edmund-architecture-contract**.
- Release/signing/appcast flags, `RELEASE_TOKEN`, Sparkle keys → **edmund-release-and-operate**.
- Interpreting log output / running a repro → **edmund-live-repro-and-diagnostics**.
- Which change needs which gate → **edmund-change-control**.
- Build-time flags in the toolchain sense (stale builds, `swift package clean`) → **edmund-build-and-env**.

---

## Provenance and maintenance

Verified 2026-07-05 against source. This skill drifts fastest — re-verify each
table before relying on it:

```bash
# §1 all keys + strings:
grep -nE 'static let [a-zA-Z]+ = "[a-zA-Z0-9._]+"' Sources/edmd/Settings/AppSettings.swift
# §1 crash toggle still commented out / endpoint still placeholder:
grep -n 'Crash reports:' Sources/edmd/Settings/AdvancedSettingsView.swift
grep -n 'reportingEndpoint' Sources/EdmundCore/Diagnostics/CrashReporter.swift
# §2 repro flag key:
grep -n 'debug.reproScript' Sources/edmd/App/ReproScript.swift
# §3 tripwire + constant:
grep -n 'willSwitchToNSLayoutManager' Sources/EdmundCore/TextView/EditorTextView.swift
grep -n 'fullLayoutMaxLength' Sources/EdmundCore/TextView/EditorTextView.swift
# §5 repro commands:
grep -oiE '"(sleep|caret|type|backspace|bypassdelete|assertcaret|logsel)"' Sources/edmd/App/ReproScript.swift | sort -u
```

**Known doc-vs-code discrepancies (code wins):** ARCHITECTURE §7 calls the
window-size key `lastWindowSize`; the code key is `settings.window.lastHeight`
(`lastWindowHeight`). If you touch window persistence, trust the code.
