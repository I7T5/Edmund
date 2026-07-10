---
name: edmund-build-and-env
description: >
  Build, environment, and toolchain runbook for the Edmund repo (native macOS
  Markdown editor; AppKit + TextKit 2, SwiftPM). Load this skill when: setting
  up the environment from scratch (fresh clone, new machine, CI mirror); a
  build fails or a "successful" build behaves stale (change "doesn't take",
  old code runs, Build complete! but nothing changed); the app crashes on
  launch or the instant it renders LaTeX; you need to construct the debug
  bundle (EdmundDbg.app) for live runs; or BEFORE trusting any binary you just
  built for a visual check or repro run. Covers swift build/test,
  build-app.sh anatomy (codesign sealing order, SwiftMath bundle placement),
  the stale-build disease and its detection, safe launch/kill hygiene around
  the user's live instance, and the CI environment.
---

# Edmund — build & environment runbook

All paths relative to the repo root.
Facts date-stamped 2026-07-05 are volatile — re-verify per the last section.

## When NOT to use this skill

| You actually need | Go to |
|---|---|
| The storage==rawSource / TextKit-2-only invariants, render pipeline | `edmund-architecture-contract` |
| Branch/commit/PR rules, what you may touch | `edmund-change-control` |
| Diagnosing a bug (not the build) | `edmund-debugging-playbook` |
| ReproScript / CGEvent live-repro driving | `edmund-live-repro-and-diagnostics` |
| Launch flags, defaults keys, settings | `edmund-config-and-flags` |
| Cutting a release, DMG, Sparkle appcast | `edmund-release-and-operate` |
| Screencapture verification method, test policy | `edmund-validation-and-qa` |

## 1. Environment from scratch

Requirements (verified 2026-07-05):

| Tool | Version | Why | Check |
|---|---|---|---|
| macOS | 14+ | `Package.swift` platforms `.macOS(.v14)` | `sw_vers` |
| Xcode | 16+ (full Xcode, not just CLT) | `swift-tools-version: 6.0`; `build-app.sh` needs `actool` | `swift --version` (local: Swift 6.0.3) |
| gh CLI | any recent | releases, PR ops | `gh --version` |
| Node | ≥20 | releases only | `node --version` |
| create-dmg | **npm** package | releases only | `npm install --global create-dmg` |

**create-dmg trap**: install via npm, NOT Homebrew. `brew install create-dmg`
is a *different tool* with an incompatible CLI. Not needed for dev work —
only for cutting releases (see `edmund-release-and-operate`).

Dependencies are fetched by SPM on first build — nothing to install by hand
(verified against `Package.swift` / `Package.resolved`, 2026-07-05):

- `swift-markdown` ≥0.5.0 (CommonMark/GFM parsing; pulls `swift-cmark` transitively)
- `SwiftMath` ≥1.7.0 (LaTeX rendering — its resource bundle is a launch-crash landmine, §3)
- `Sparkle` ≥2.6.0 (auto-update — its framework is a dyld-abort landmine, §4)

Two SPM targets: **EdmundCore** (library + all tests; most work happens here)
and **edmd** (the app shell executable). The binary is named `edmd` even
though the app presents as "Edmund" — deliberate, see the comment in
`Package.swift`.

## 2. Core commands

```bash
swift build                    # debug build of both targets
swift test                     # full suite: ~750+ tests, ~10s (2026-07-05)
swift test --filter Callout    # one suite
./scripts/build-app.sh         # release build → build/Edmund.app
```

`swift test` also runs automatically as a Stop hook after code-touching turns.

## 3. What build-app.sh actually does (and why the order matters)

`scripts/build-app.sh` → `build/Edmund.app`. Steps, in order:

1. `swift build -c release`
2. Assemble `build/Edmund.app/Contents/{MacOS,Resources}`; copy
   `.build/release/edmd`, `Info.plist`, `Resources/AppIcon.icns`.
3. Compile `Resources/Assets.xcassets` with `actool` (falls back to
   `/Applications/Xcode.app/.../actool` if xcode-select points at the CLT).
4. Embed `Sparkle.framework` into `Contents/Frameworks/` (found under
   `.build/`; SwiftPM links Sparkle but never copies the framework — without
   it the updater crashes on first check) and `install_name_tool -add_rpath
   "@executable_path/../Frameworks"` so `@rpath` resolves post-install.
5. Codesign **inside-out**: Sparkle.framework first (nested XPC helpers must
   be signed before macOS will launch them), then the whole `.app` (ad-hoc,
   `--deep`, identifier `com.i7t5.edmd`). Sealing the *bundle* — not just the
   binary — is what Sparkle's update validator requires.
6. **Only after sealing**: copy `.build/release/*.bundle` (SwiftMath's math
   fonts) into the `.app` **root**.

Why step 6 is last and at the root — two constraints collide:

- `codesign` refuses to seal a bundle with any extra item at the `.app` root
  ("unsealed contents present in the bundle root"), so the seal must happen
  while the root holds only `Contents/`.
- SwiftMath's generated `Bundle.module` accessor hardcodes
  `Bundle.main.bundleURL` — the `.app` root — with only a hardcoded absolute
  `.build` path as fallback. So the bundle *must* sit at the root.

Resolution: seal first, copy after. The one unsealed root item makes
`codesign --verify` and `--strict` complain, but Sparkle's actual check is
non-strict and tolerates it (verified end-to-end; details in
`docs/ARCHITECTURE.md` §8).

**Missing SwiftMath bundle = instant crash the moment the app renders any
LaTeX.** App launches fine, opens documents fine, dies on the first math
block. If you see that crash, check `ls build/Edmund.app/*.bundle` first.

## 4. Debug bundle fast path (EdmundDbg.app)

For live runs of a *debug* build, skip `build-app.sh` and hand-assemble
(from `docs/dev-guides/live-repro-guide.md` §4):

```bash
swift build
mkdir -p build/EdmundDbg.app/Contents/MacOS
cp Info.plist build/EdmundDbg.app/Contents/
cp .build/arm64-apple-macosx/debug/edmd build/EdmundDbg.app/Contents/MacOS/
cp -R .build/arm64-apple-macosx/debug/Sparkle.framework build/EdmundDbg.app/Contents/MacOS/
```

- **Sparkle.framework must sit next to the binary** — dyld aborts without it.
- A bare `.build/debug/edmd` runs but **never creates a window**. It needs
  the bundle (Info.plist) around it.
- **Launch by direct exec of the bundle binary, never `open -a`**:

```bash
build/EdmundDbg.app/Contents/MacOS/edmd /path/to/test.md \
  -ApplePersistenceIgnoreState YES &
```

  LaunchServices (`open -a`) can silently run a stale cached/translocated
  copy — you'd be executing last hour's code. Direct exec runs exactly the
  binary you just copied. `-ApplePersistenceIgnoreState YES` stops state
  restoration from reopening previous (possibly mutated) documents.
- Recreate the test document fresh before every run — autosave mutates it.

## 5. THE STALE BUILD DISEASE

The single most expensive trap in this repo: it has produced entire wrong
debugging conclusions ("my fix doesn't work" when the fix was never in the
binary).

**Symptom**: `swift build` prints `Build complete!` having compiled a changed
file but **not relinked `edmd`**. The app then runs old code. Release builds
(`swift build -c release` / `build-app.sh`) reuse stale objects too.

**Detection — before trusting ANY binary you just built:**

```bash
# 1. Grep for a LONG string literal unique to your new code:
strings .build/arm64-apple-macosx/debug/edmd | grep 'your long unique literal'
# 2. Hash before/after the build:
shasum .build/arm64-apple-macosx/debug/edmd
```

**Literal length matters**: string literals ≤15 bytes are stored inline in
the Mach-O on arm64 and *never appear* in `strings` output. A short probe
literal gives a false "stale" verdict. Use a long one (a distinctive log
message works well).

**Cure:**

```bash
swift package clean          # first resort
rm -rf .build                # visual change "doesn't take" → nuke it all
```

**Never hand-delete `.build/…/edmd.build/`** — that corrupts SwiftPM's
output-file-map and wedges the target until a full clean anyway.

## 6. Running for visual checks — launch/kill hygiene

**The user's daily-driver app has the same binary name (`edmd`).** A blanket
`pkill -x edmd` kills their live session. Always, in order:

```bash
# 1. Who is running, and since when?
pgrep -lx edmd
ps -o lstart=,command= -p <pid>
# 2. Kill ONLY your own PID — or, if you launched the debug bundle:
pkill -f EdmundDbg
```

Other run gotchas:

- `open Edmund.app` **foregrounds a running instance instead of
  relaunching** — you'll be looking at the old binary. Kill your instance
  first or direct-exec the binary.
- Always pass `-ApplePersistenceIgnoreState YES` (see §4).
- After many rapid launch/kill cycles the window server can glitch (tiny
  windows, broken state restoration):
  `rm -rf ~/Library/"Saved Application State"/com.i7t5.edmund.savedState`
  and relaunch.
- Verification method (window-id screencapture, offscreen render fallback):
  `edmund-validation-and-qa` and `docs/ARCHITECTURE.md` §8.

## 7. CI environment

`.github/workflows/ci.yml` (verified 2026-07-05): runs `swift test` on
`macos-14` with `latest-stable` Xcode (Swift 6.0 needs Xcode 16+), triggered
on PRs and pushes to `main`.

- **SPM cache**: `.build` is cached keyed on
  `spm-v2-${{ runner.os }}-${{ hashFiles('Package.resolved') }}`. The `v2`
  token exists because the repo rename `md` → `Edmund` changed the checkout
  path and invalidated absolute paths baked into the cached module cache —
  bump the token to discard a poisoned cache.
- **Concurrency**: `cancel-in-progress: true` per branch/PR — private-repo
  macOS minutes bill at 10x, so superseded commits' runs are cancelled.
- Release pipeline (`release.yml`, tag-triggered) is a separate beast:
  `edmund-release-and-operate` / `docs/ARCHITECTURE.md` §13.

## 8. Checklists

### Fresh clone to green

- [ ] `sw_vers` — macOS 14+; `swift --version` — Swift 6.x (Xcode 16+)
- [ ] `git clone` + `cd Edmund`
- [ ] `swift build` — SPM fetches swift-markdown, SwiftMath, Sparkle
- [ ] `swift test` — ~750+ tests green in ~10s
- [ ] Read `docs/ARCHITECTURE.md` (mandated by CLAUDE.md before non-trivial work)
- [ ] Visual work planned? `./scripts/build-app.sh`, confirm
      `build/Edmund.app` exists and `ls build/Edmund.app/*.bundle` shows the
      SwiftMath bundle
- [ ] Releases planned? `node --version` ≥20, `npm install --global create-dmg`

### Before trusting any run

- [ ] Binary is fresh: `strings <binary> | grep '<long unique literal>'`
      and/or `shasum` changed since the edit (§5)
- [ ] `pgrep -lx edmd` — user's live instance identified; you will kill only
      your own PID (§6)
- [ ] Launched by direct exec, not `open -a` (§4)
- [ ] `-ApplePersistenceIgnoreState YES` passed
- [ ] Test document recreated fresh (autosave mutated the last one)
- [ ] Debug bundle: Sparkle.framework sits next to the binary
- [ ] Release bundle: SwiftMath `*.bundle` at the `.app` root (or the first
      LaTeX render crashes)

## Provenance and maintenance

Every claim above was read from the files below on 2026-07-05. Re-verify:

- Toolchain/deps: `cat Package.swift` (tools-version, platforms, dep
  versions); `grep identity Package.resolved`
- Build anatomy: `cat scripts/build-app.sh` (step order, sealing comments)
- Test count/time: `swift test 2>&1 | tail -3`
- Debug bundle recipe: `docs/dev-guides/live-repro-guide.md` §4
- Stale-build disease, launch gotchas: `docs/ARCHITECTURE.md` §8
  ("Stale release builds", "open Edmund.app", savedState)
- CI facts: `cat .github/workflows/ci.yml` (cache key comment, concurrency)
- create-dmg quirks: `docs/ARCHITECTURE.md` §8 ("create-dmg — npm only")

If a command here disagrees with those files, the files win — update this
skill.
