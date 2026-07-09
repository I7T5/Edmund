---
name: edmund-release-and-operate
description: >
  Load when cutting or debugging an Edmund release, or operating the shipped
  app. Triggers: version bump (Info.plist CFBundleShortVersionString /
  CFBundleVersion), tagging vX.Y.Z, CHANGELOG.md release sections, release.yml
  / release.sh / build-app.sh, appcast.xml or Sparkle update failures
  ("improperly signed", update never offered), sign_update / EdDSA keys /
  SPARKLE_ED_PRIVATE_KEY / RELEASE_TOKEN, create-dmg or DMG naming problems,
  Gatekeeper "damaged" reports, launching the built app, reading
  ~/.edmund/logs, crash reports (edmd-*.ips), or roadmap/priority questions.
---

# Edmund — release & operate

Date-stamped 2026-07-05. Verified against `.github/workflows/release.yml`,
`scripts/release.sh`, `scripts/build-app.sh`, `scripts/changelog-to-html.py`,
`appcast.xml`, `Info.plist`, `CHANGELOG.md`, `docs/ARCHITECTURE.md` §8/§13, and
the Settings/CrashReporter sources. Where a doc and a script disagree, the
script is the truth; disagreements are flagged inline.

**House rule: releases happen only when the maintainer explicitly asks.**
Never tag, push, create a release, or merge on your own initiative — see
`edmund-change-control`. Everything in §1–§4 below is a runbook for when the
maintainer says "cut a release", not a standing instruction.

## When NOT to use this skill

| You actually need | Go to |
|---|---|
| Build/test commands, stale-build cures, launch mechanics in depth | `edmund-build-and-env` |
| Editing invariants, render pipeline, TextKit 2 rules | `edmund-architecture-contract`, `textkit2-appkit-reference` |
| Debugging a bug in the app itself | `edmund-debugging-playbook`, `edmund-live-repro-and-diagnostics` |
| Past incidents and why the sharp edges below exist | `edmund-failure-archaeology` |
| Debug flags / launch arguments | `edmund-config-and-flags` |
| Branch/commit/PR etiquette, what needs maintainer sign-off | `edmund-change-control` |
| Pre-merge QA method | `edmund-validation-and-qa` |
| README/website/positioning copy | `edmund-docs-and-writing`, `edmund-external-positioning` |

---

## 1. Release flow — CI path (the normal one)

Ship via a tag; CI does the rest. In order:

1. **Bump versions in `Info.plist`** — both keys:
   - `CFBundleShortVersionString` — marketing version, e.g. `0.1.3`
   - `CFBundleVersion` — build number, **monotonic integer** (0.1.3 = `4`)
2. **Add a `## [x.y.z]` section to `CHANGELOG.md`** — format is load-bearing,
   see §2. The version MUST match Info.plist exactly.
3. **Merge to `main`** and push (via the normal PR flow).
4. **Tag and push the tag:**
   ```sh
   git tag vX.Y.Z && git push origin vX.Y.Z
   ```
5. CI (`.github/workflows/release.yml`, trigger `push: tags: 'v*'`, runner
   `macos-14`, job `release` / "Build & publish") runs the steps below.
6. Afterwards, verify per §4 post-flight.

### release.yml step anatomy (actual step names)

| Step | What it does | Sharp edge |
|---|---|---|
| `actions/checkout@v5` | `fetch-depth: 0`, `token: ${{ secrets.RELEASE_TOKEN }}` | The PAT must be on **this** step — see §3.4 |
| `maxim-lobanov/setup-xcode@v1` | latest-stable Xcode | |
| **Cache .build** | SPM cache keyed on `Package.resolved` | |
| **Build app bundle** | `./scripts/build-app.sh` — release build, bundle assembly, Sparkle embed, **bundle sealing** | §3.2 |
| `actions/setup-node@v4` | pins Node 20 | create-dmg 8.x needs Node ≥ 20 |
| **Install create-dmg** | `npm install --global create-dmg` (sindresorhus/create-dmg, **not** Homebrew's) | §3.5 |
| **Create DMG** | reads VERSION from Info.plist, `create-dmg build/Edmund.app build/ \|\| true`, renames `"Edmund <v>.dmg"` → `Edmund-<v>.dmg`, fails loudly if no dmg | §3.5 |
| **Sign archive (EdDSA)** | finds `sign_update` in `.build`, key on **stdin** via `--ed-key-file -`, exports `ED_SIG` and `LENGTH` | §3.1 |
| **Create GitHub Release** | awk-extracts the CHANGELOG section → `gh release create "v${VERSION}" build/Edmund-${VERSION}.dmg --title "Edmund ${VERSION}" --notes-file … --latest` | §2 |
| **Update appcast.xml** | builds the new `<item>` (HTML `<description>` via `scripts/changelog-to-html.py`), inserts it before `</channel>`, commits as `github-actions[bot]`, `git push origin HEAD:main` | §3.4 |

### Local path (`scripts/release.sh`)

Mirrors CI: build-app.sh → create-dmg (+ rename) → EdDSA sign → update
appcast.xml **locally** → `gh release create`. Two differences:

- **Signing**: with `SPARKLE_ED_PRIVATE_KEY` in the env it uses the stdin path
  (CI-style); otherwise `sign_update` pulls the key from the **login keychain**
  (put there by Sparkle's `generate_keys`) with no flag at all.
- **The appcast commit/push is left to you.** The script ends with the exact
  commands: `git add appcast.xml && git commit -m 'Release <v>' && git push`.

Prereqs for the local path: `gh auth status` authenticated, npm `create-dmg`
installed, `swift build` has run at least once (so `sign_update` exists under
`.build`).

> **Stale doc**: `misc/how-to-release.md` still says the artifact is a **zip**
> ("signs the zip", "Zip it to build/Edmund-1.0.zip"). That predates the DMG
> switch. The truth is DMG throughout — per `release.yml`, `release.sh`, and
> ARCHITECTURE §13. Trust the scripts, and fix that doc when touching it.

---

## 2. CHANGELOG format contract (release notes are machine-extracted)

Both `release.yml` and `release.sh` extract the GitHub Release body with:

```sh
awk "BEGIN{p=0} /^## \[${VERSION}\]/{p=1;next} p && /^## \[/{exit} p{print}" CHANGELOG.md
```

So the section header **must** start at column 0 as `## [x.y.z]` — literally
`## [0.1.3] — 2026-07-04` in house style (em dash + ISO date after the
bracket is fine; the match only requires the `^## \[x.y.z\]` prefix).
Extraction runs until the next `^## [` line. If nothing matches, the release
body falls back to "See CHANGELOG for details." — a silent-ish failure, so get
the header right. (Version dots are unescaped in the regex; harmless in
practice, don't rely on it.)

The Sparkle update-dialog notes come from the **same section** via
`scripts/changelog-to-html.py <version>`, a deliberately tiny converter that
only understands Keep-a-Changelog shapes:

- `### Added` / `### Changed` / `### Fixed` → `<h3>` — **use `###`, not `##`**.
  The 0.1.2 appcast item literally shows `<p>## Changed</p>` because the
  section used `##` subheads at release time; the converter passed them
  through as paragraphs.
- `- ` / `* ` bullets → `<ul><li>`; indented continuation lines fold into the
  previous bullet.
- `` `code` `` and `**bold**` are converted. **Markdown links are NOT** —
  `[docs](docs/foo.md)` appears literally in the update dialog (see the 0.1.2
  item). Keep appcast-facing notes link-free or accept the raw brackets.
- Blank lines and `---` are skipped; anything else becomes a `<p>`.
- Missing section → empty output → the `<description>` is simply omitted.

House format (verified from `CHANGELOG.md`): Keep a Changelog 1.1.0 + SemVer,
newest first, sections separated by `---`.

---

## 3. The sharp edges (each one killed or nearly killed a real release)

### 3.1 `sign_update -s` is FATAL — key goes on stdin

Sparkle deprecated `-s <key>`; for newly generated keys it prints a
deprecation warning and **exits 1** ("no longer supported"). This killed the
first 0.1.0 release. The only correct invocation with a key-in-hand:

```sh
echo "$SPARKLE_ED_PRIVATE_KEY" | sign_update --ed-key-file - <dmg>
```

Both `release.yml` and `release.sh` do exactly this. Never "simplify" it back
to `-s`. Output format: `sparkle:edSignature="<sig>" length="<n>"` — the
scripts grep those two attributes out for the appcast item.

### 3.2 Bundle sealing (the "improperly signed" update failure)

At install time Sparkle re-validates the update's **Apple** code signature
(`SUUpdateValidator`), independent of the EdDSA signature. A bundle that is
code-signed but not *sealed* (no `_CodeSignature/CodeResources`) fails that
check and every update dies with "The update is improperly signed and could
not be validated" — which is exactly what broke the v0.1.0 → 0.1.1 update
when the old script signed only the bare binary.

`build-app.sh` therefore signs inside-out and in a very deliberate order:

1. `codesign --force --deep --sign - Sparkle.framework` (nested XPC helpers
   must be signed before macOS will launch them),
2. `codesign --force --deep --sign - --identifier "com.i7t5.edmd"` on the
   whole `.app` **while its root holds only `Contents/`** — codesign refuses
   to seal a bundle with extra items at the root,
3. copy the SwiftMath resource bundle to the `.app` root **after** sealing
   (its generated `Bundle.module` looks at `Bundle.main.bundleURL`; without it
   the app crashes on the first LaTeX render).

Consequence: `codesign --verify` (CLI) and `--strict` **will complain** about
that one unsealed root item. That is expected and fine — Sparkle's actual
check is non-strict (`SecStaticCodeCheckValidityWithErrors` with
`kSecCSCheckAllArchitectures`) and tolerates it; verified end-to-end against
that API. Do not "fix" the verify warning by moving the SwiftMath bundle or
re-signing after the copy.

### 3.3 Keypair discipline

One EdDSA keypair, three places, all of which must agree:

| Place | Used by |
|---|---|
| `Info.plist` `SUPublicEDKey` (`0XdLbbuO…`) | Every shipped app, to verify updates |
| Maintainer's **login keychain** | `release.sh` local signing (no flag) |
| GitHub secret **`SPARKLE_ED_PRIVATE_KEY`** | CI signing |

If the signing key and `SUPublicEDKey` diverge, everything *looks* fine — the
DMG signs without error — but **every user's update fails signature
verification**. Sanity check when in doubt:
`sign_update --verify <dmg> <sig>` against the Info.plist public key.

### 3.4 Appcast push to protected `main` — RELEASE_TOKEN

The workflow's last step commits `appcast.xml` and pushes to `main`, which
requires the `test` status check. The default `GITHUB_TOKEN` /
`github-actions[bot]` is not an admin, so that push is rejected with
`GH006 … protected branch hook declined`. Branch protection has
`enforce_admins: false`, so an admin's push bypasses the check — hence the
fine-grained **admin PAT** in the `RELEASE_TOKEN` secret (Contents:
read/write), set as the `token:` on the **checkout step**, not on the push.
That placement matters: `actions/checkout` persists an
`http.<host>.extraheader` credential that overrides inline-URL credentials,
so rewriting the push URL would keep pushing with the bot token anyway.

**`RELEASE_TOKEN` expires 2027-06-27.** Rotate it before then or every
release fails at the appcast push while the GitHub Release itself succeeds
(a confusing half-shipped state — see §4 post-flight).

### 3.5 create-dmg quirks

- It's the **npm** package `create-dmg` (sindresorhus), installed via
  `npm install --global create-dmg`. Homebrew's `create-dmg` is a different
  tool with an incompatible CLI. Requires Node ≥ 20 (CI pins it).
- It exits **2** when it can't Developer-ID-sign/notarize the image (Edmund
  ships ad-hoc) **but still produces the .dmg**. Both scripts run it with
  `|| true` and then verify the file exists, failing loudly only if no dmg
  was produced. Don't remove the `|| true`; don't trust the exit code.
- Output is named `"Edmund <version>.dmg"` — with a **space**. Both scripts
  rename to `Edmund-<version>.dmg` (hyphen), which is the name the appcast
  enclosure URL expects. If a rename is skipped, the release asset URL 404s
  for every updater.

---

## 4. Pre-flight and post-flight

### Pre-flight (distilled from `misc/before-you-release.md` — read it too)

- [ ] `swift test` green **on `main`**, not just the branch; `git status` clean.
- [ ] No debug flags / launch args left on (repro drivers, verbose tracing —
      see `edmund-config-and-flags`, ARCHITECTURE §8).
- [ ] Visual sanity: build and screencapture the editor in **light and dark**
      mode; click through everything the CHANGELOG claims ("fixed X" → actually
      reproduce X and confirm).
- [ ] `CHANGELOG.md` has `## [x.y.z] — YYYY-MM-DD` for this release and the
      version **matches Info.plist** (`CFBundleShortVersionString`); `###`
      subheads, not `##` (§2).
- [ ] `CFBundleVersion` bumped (monotonic int).
- [ ] `RELEASE_TOKEN` not expired (**2027-06-27**).
- [ ] Local path only: `gh auth status` ok; keychain key matches
      `SUPublicEDKey` (§3.3).

### Post-flight

- [ ] GitHub Release `vX.Y.Z` exists with the right notes and the
      `Edmund-<v>.dmg` asset (hyphenated name).
- [ ] `appcast.xml` on `main` got the new `<item>` — with `<description>`,
      correct `sparkle:version` (= CFBundleVersion) and enclosure URL.
- [ ] Nothing to do for user prompts: Sparkle checks roughly daily; existing
      users see the update within ~24 h. Don't panic if it isn't instant.

If the Release exists but the appcast commit is missing, the release
half-shipped (usually §3.4). Fix the token, then add the `<item>` manually or
re-run the job.

---

## 5. Gatekeeper story (why users see "damaged")

Edmund is **ad-hoc signed, not notarized** (no $99/yr Developer ID). First
launch of a downloaded copy trips Gatekeeper with the *"app is damaged"*
dialog. This is expected; the app is fine. The README documents both
workarounds (verified, README ~line 53):

- `xattr -dr com.apple.quarantine /Applications/Edmund.app`, or
- right-click → Open.

Known upgrade path (open/candidate, not scheduled): Developer ID certificate
+ notarization would remove the prompt entirely and also clean up the
non-strict-sealing compromise in §3.2. Don't promise it in user-facing text.

---

## 6. Operating the app

### Launching

`open Edmund.app` **foregrounds a running instance instead of relaunching** —
you'll stare at old code. And never `pkill -x edmd` blindly: the maintainer's
own Edmund session may be running (the Mach-O is `edmd` for both). Check
first (`pgrep -x edmd`), kill only PIDs you started, or launch the binary
directly: `build/Edmund.app/Contents/MacOS/edmd file.md &`. Full launch /
stale-build / screencapture mechanics: `edmund-build-and-env`.

### Logs — `~/.edmund/logs/edmund-YYYY-MM-DD.log`

- One file per day, human-readable lines tagged `LEVEL [category]`
  (categories: app, document, io, render, compose, selection, lazy, callout,
  edit — grep by concern).
- Controlled by **Settings ▸ Advanced ▸ Diagnostics** ("Save diagnostic
  logs"). The toggle **defaults OFF** (`AppSettings.diagnosticLogging`
  defaults false) — i.e. opt-in in the shipped app, despite `Log.swift`'s
  header comment calling it "always-on (opt-out)"; the code is the truth.
  (The UserDefaults keys are named `settings.general.*` for legacy reasons;
  the UI lives in Advanced.)
- Retention picker ("Clear logs after:") next to the toggle; a separate
  "Verbose editor tracing" opt-in gates keystroke-level trace lines — leave
  off except during repros (`edmund-live-repro-and-diagnostics`).
- Release builds write `info` and up; DEBUG builds also write `debug`.
- Logs may contain document text; they never leave the machine.

### Crash reports — `~/Library/Logs/DiagnosticReports/edmd-*.ips`

- macOS names crash reports after the **Mach-O executable**: look for
  `edmd-<timestamp>.ips`, not "Edmund-…".
- **Uploading is opt-in and currently INERT.** The Settings toggle is
  commented out in `Sources/edmd/Settings/AdvancedSettingsView.swift` ("dormant
  until the receiving server exists"), and
  `CrashReporter.reportingEndpoint` is a placeholder
  (`https://REPLACE-ME.invalid/crash`). Nothing is ever sent in shipped
  builds. Don't tell users crash reporting exists; don't uncomment the toggle
  without a real server. Code: `Sources/EdmundCore/Diagnostics/CrashReporter.swift`.
- Reading works only because Edmund is **not sandboxed**; adopting App
  Sandbox would force a MetricKit rewrite (noted in CrashReporter's header).
- **Triage of a user's `.ips`**: it's JSON — a one-line metadata header, then
  the report body. Look at `exception` (type/signal), `faultingThread`, and
  walk that thread's frames for images named `edmd` or `Sparkle`. Ad-hoc
  builds ship no dSYM, so expect addresses rather than symbol names for app
  frames; correlate with `~/.edmund/logs` from the same timestamp instead.
  `.ips` files embed the user's home path and device model — treat as
  mildly personal data.

### Update mechanics (user side)

- `SUFeedURL` = `https://raw.githubusercontent.com/I7T5/Edmund/main/appcast.xml`
  — the raw-GitHub URL of the checked-in appcast; committing to `main` *is*
  publishing.
- `SUEnableAutomaticChecks` is true; no custom interval is set, so Sparkle
  uses its default ~24 h cadence (plus a check on launch).
- Sparkle downloads the DMG enclosure, verifies EdDSA against `SUPublicEDKey`,
  **mounts the DMG**, re-validates the Apple code signature (§3.2), installs.

---

## 7. Versioning & appcast conventions

| Thing | Convention | Current (2026-07-05) |
|---|---|---|
| Git tag | `vX.Y.Z` | `v0.1.3` pending its tag; last released 0.1.2 |
| `CFBundleShortVersionString` | SemVer marketing version | `0.1.3` |
| `CFBundleVersion` | monotonic integer, +1 per release | `4` |
| CHANGELOG | Keep a Changelog 1.1.0, `## [x.y.z] — YYYY-MM-DD`, `###` subheads, `---` separators | — |

`appcast.xml` (checked into repo root): RSS 2.0 with the `sparkle:` namespace.
One `<channel>` (title/link/description/language) containing one `<item>` per
release. Items are inserted **before `</channel>`**, so the file reads oldest
→ newest; Sparkle doesn't care about order — it picks by version. Per item:

```xml
<item>
    <title>Edmund 0.1.2</title>
    <pubDate>Fri, 03 Jul 2026 19:03:59 +0000</pubDate>
    <description><![CDATA[ …HTML from changelog-to-html.py… ]]></description>
    <enclosure url="https://github.com/I7T5/Edmund/releases/download/v0.1.2/Edmund-0.1.2.dmg"
               sparkle:version="3"                <!-- CFBundleVersion -->
               sparkle:shortVersionString="0.1.2" <!-- marketing version -->
               sparkle:edSignature="…"
               length="7608991"
               type="application/x-apple-diskimage"/>
</item>
```

`<description>` is optional (omitted when the CHANGELOG section is missing).

---

## 8. Roadmap context (for release-content judgment)

- Edmund is in **beta** (0.1.x line, first public release 0.1.0 on
  2026-06-27). Small, frequent releases.
- **v0.2.0 goal: "Polished editing experience"** (`misc/backlog.md` § Now).
- **Priority ordering: Marketing = Bugs >= UI/UX > Features** — when deciding
  what makes a release, bug fixes and polish beat new features.
- Long-range plan (v1.0 = onboarding + full GFM + extensions groundwork):
  `docs/ROADMAP.md`; working backlog with per-bug detail: `misc/backlog.md`.

---

## Provenance and maintenance

Written 2026-07-05 from direct reads of: `.github/workflows/release.yml`,
`scripts/release.sh`, `scripts/build-app.sh`, `scripts/changelog-to-html.py`,
`appcast.xml`, `CHANGELOG.md`, `Info.plist`, `README.md`,
`docs/ARCHITECTURE.md` (§8, §13), `misc/how-to-release.md`,
`misc/before-you-release.md`, `docs/ROADMAP.md`, `misc/backlog.md`,
`Sources/EdmundCore/Diagnostics/CrashReporter.swift`,
`Sources/EdmundCore/Diagnostics/Log.swift`,
`Sources/edmd/Settings/AdvancedSettingsView.swift`,
`Sources/edmd/Settings/AppSettings.swift`.

Known stale docs at time of writing: `misc/how-to-release.md` (zip vs DMG,
§1); `Log.swift` header ("always-on (opt-out)" vs the actual default-off
toggle, §6). Minor oddity, deliberate: `build-app.sh` signs with
`--identifier "com.i7t5.edmd"` while the bundle id is `com.i7t5.edmund`.

Re-verify when any of these change: `release.yml` step names or secrets,
`build-app.sh` signing order, the CHANGELOG header format (the awk regex in
two places must match it), `SUFeedURL`, `RELEASE_TOKEN` rotation (hard
deadline 2027-06-27), notarization status, or the crash-report server going
live (which un-inerts §6's crash uploading and this skill's wording).
