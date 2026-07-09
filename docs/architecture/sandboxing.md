# App Sandbox: preparation plan

**Status: design and preparation only. Nothing on `main` is sandboxed today.**
This is the plan of record for adopting the App Sandbox ahead of an App Store
build, modeled on CotEditor's approach. Facts about CotEditor were verified
against `coteditor/CotEditor` on 2026-07-09; facts about Edmund were surveyed
on `main` the same day. When a stage below lands, move its facts into
`../ARCHITECTURE.md` in the same PR.

## 1. Where Edmund stands

- **No entitlements file exists anywhere in the repo.** `scripts/build-app.sh`
  ad-hoc signs (`codesign --force --deep --sign -`) with no `--entitlements`
  argument. The app is unsandboxed by construction.
- **`Info.plist` lacks `LSApplicationCategoryType`**, which the App Store
  requires.
- **Distribution is GitHub releases plus Sparkle** (`SUFeedURL` pointing at
  `appcast.xml` on `main`, EdDSA-signed updates). There is no
  GitHub-vs-App-Store switch anywhere in the code or build scripts.
- Several shipping features currently depend on unrestricted filesystem
  access. §3 inventories them.

## 2. The reference model: CotEditor

CotEditor sandboxes **every** build variant, not only the App Store one. The
pieces:

- **Three entitlements files**, one per distribution:
  `CotEditor.entitlements` (App Store), `CotEditor-Sparkle.entitlements`
  (notarized direct download), `CotEditor-AdHoc.entitlements` (local/dev).
  All three set `com.apple.security.app-sandbox`,
  `files.user-selected.read-write`, and `print`. The Sparkle variant adds
  `com.apple.security.network.client` plus two
  `temporary-exception.mach-lookup.global-name` entries,
  `$(PRODUCT_BUNDLE_IDENTIFIER)-spks` and `…-spki`. Those are Sparkle 2's
  sandbox XPC services; its Info.plist also sets
  `SUEnableInstallerLauncherService = true`.
- **Variant selection lives in build configuration, not code structure.**
  Each variant's xcconfig points `CODE_SIGN_ENTITLEMENTS` at its file. The
  Sparkle variant sets `SWIFT_ACTIVE_COMPILATION_CONDITIONS = SPARKLE`; the
  App Store variant excludes `Sparkle*` source files outright. Updater code
  compiles only under `#if SPARKLE`.
- **User-supplied setting files are imported under
  `startAccessingSecurityScopedResource()`**
  (`SettingFileManaging.swift`), and CotEditor's own themes live inside the
  sandbox container's Application Support, so it never needs a standing
  grant to a home-directory folder.

**What transfers to Edmund**: sandbox everywhere so there is one behavior to
test; Sparkle stays in the sandboxed GitHub build; a variant is nothing more
than an entitlements file plus a compile flag plus a source exclusion.

**What does not transfer**: Edmund's themes/extensions design puts
user-managed files in `~/.edmund/` (see [`extensibility.md`](extensibility.md)
§3), outside any container, so Edmund needs the onboarding grant described in
§4, which CotEditor never needed. CotEditor's iCloud entitlements are out of
scope for now. And Edmund is SPM plus a shell script rather than an Xcode
project, so "xcconfig" translates to `build-app.sh` arguments (§5).

## 3. Touchpoint inventory and fix map

Everything on `main` that breaks or needs review under the sandbox.

- **`~/.edmund/logs` (two independent computations).** `Log.swift` and
  `AppSettings.logDirectory` each build the path from
  `homeDirectoryForCurrentUser`. Raw home-directory access is invisible to a
  sandboxed process (it sees the container's home). Fix: the path-provider
  seam already designated in [`extensibility.md`](extensibility.md) §4, backed
  by the security-scoped bookmark from the onboarding grant (§4 below). Until
  a grant exists, the seam falls back to a container-local log directory so
  logging never silently dies.
- **Crash reporter.** `CrashReporter.swift` reads other processes' `.ips`
  files from `~/Library/Logs/DiagnosticReports`, which no entitlement can
  reach; its own header already names MetricKit as the sandbox replacement.
  The feature is dormant (placeholder endpoint, UI commented out). Fix: swap
  to MetricKit if the feature ever ships; until then compile it out or no-op
  it in sandboxed builds. Its `URLSession` upload would additionally need
  `network.client`.
- **Sibling images (the big one).** `EditorTextView+ImageRendering.swift`
  resolves relative image paths against the document's folder, and
  `DocumentHTML.swift` reads the same files to inline `data:` URIs for read
  mode and PDF export. Opening `notes.md` grants access to `notes.md` only,
  not to `diagram.png` next to it, so every relative image breaks under the
  sandbox. Options considered:
  1. **Per-folder grant (recommended).** On the first sibling access that
     fails, prompt once with an `NSOpenPanel` preset to the document's
     folder, store a security-scoped bookmark keyed by folder, reuse it for
     every document in that folder. This is the pattern document-based
     App Store editors use.
  2. Document-scoped bookmarks stored per document: needs somewhere to put
     the bookmark, which plain `.md` files do not offer.
  3. Do nothing and let relative images break: unacceptable for a Markdown
     editor whose selling point is live preview.
- **Wiki links.** `EditorTextView+WikiLinks.swift` resolves a direct child
  and then recursively enumerates the whole document directory to find a
  target by name. Both need the same per-folder grant as sibling images.
  Programmatic `openDocument` on a URL the app cannot read fails rather than
  prompting, so resolution must happen inside the granted scope.
- **Absolute and tilde paths in Markdown.** `~/…` and `/…` image and link
  paths (`ImageRendering`, `WikiLinks`, `DocumentHTML`) fail outside granted
  scopes. Behavior: degrade gracefully (broken-image placeholder, dead
  link), and document that granting the containing folder revives them. No
  entitlement fixes arbitrary absolute paths, by design.
- **Rename and Move.** `Document.swift` calls `FileManager.moveItem`
  directly. Source (the open document) and destination (an `NSSavePanel`
  choice) are both inside granted scopes, so this likely works, but it
  bypasses file coordination. Label: verify under a sandboxed build in
  Stage SB1; if it misbehaves, switch to `NSDocument.move(to:)`.
- **Sparkle.** Keep it in the sandboxed GitHub build, CotEditor-style:
  `network.client`, the `-spks`/`-spki` mach-lookup exceptions, and
  `SUEnableInstallerLauncherService = true` in Info.plist. The App Store
  variant excludes Sparkle entirely: `#if SPARKLE` around the import, the
  `SPUStandardUpdaterController`, and the "Check for Updates…" menu item in
  `main.swift`; `build-app.sh` skips embedding the framework; the `SU*`
  Info.plist keys go away.
- **Read mode and PDF export.** The `WKWebView`s load HTML strings with
  images pre-inlined as `data:` URIs and do no file access of their own, so
  they are unaffected once the inlining path (sibling images above) has
  access. Printing needs the `print` entitlement.
- **`NSWorkspace.shared.open` on external links**: allowed under the
  sandbox, no entitlement needed.
- **ReproScript (DEBUG only).** The sandbox blocks posting `CGEvent`s, which
  would kill the live-repro driver. Recommendation: the local dev build
  stays unsandboxed so the diagnostics tooling keeps working, and sandboxed
  builds are an explicit `build-app.sh` variant you build when testing
  sandbox behavior. This deliberately diverges from CotEditor's
  sandbox-everywhere stance; Edmund's live-repro tooling is worth the split.
- **Preferences migration (open question).** A sandboxed app reads defaults
  from its container, not `~/Library/Preferences/com.i7t5.edmund.plist`.
  Whether macOS migrates existing preferences into the container on first
  sandboxed launch must be verified in Stage SB1 with a real upgrade
  scenario; if it does not, existing users lose settings and the migration
  needs handling before any sandboxed release ships.
- **Confirmed non-issues**: no `Process`/`NSTask`, no AppleScript, no direct
  pasteboard types beyond stock `NSText` behavior, no screen capture, no
  IOKit.

## 4. The `~/.edmund/` grant

The onboarding flow (planned, not yet built) asks the user to grant access
to `~/.edmund/` once:

1. Explain why (themes and extensions live there, VSCode/Obsidian style).
2. Present an `NSOpenPanel` with `canChooseDirectories`,
   `canCreateDirectories`, and `directoryURL` preset to the home directory,
   prompt text "Grant Access". The panel is the sandbox-blessed way to turn
   a user gesture into filesystem access, and it lets the user create
   `~/.edmund` if it does not exist yet.
3. Persist `url.bookmarkData(options: .withSecurityScope)` in UserDefaults.
4. On every launch, resolve the bookmark, call
   `startAccessingSecurityScopedResource()`, and hold the access for the
   app's lifetime. If resolution reports the bookmark stale, re-request via
   the same panel flow.

The path-provider seam is the only consumer of this bookmark. Built without
the sandbox flag, the seam returns the raw home-directory URL and the grant
machinery compiles out. Before a grant exists (first launch, declined
onboarding), the seam falls back to container-local paths for logs and
reports themes/extensions as unavailable rather than crashing or silently
writing elsewhere.

Open sub-decision: whether the panel must land exactly on `~/.edmund` (reject
other choices) or any folder is accepted and treated as the root. Requiring
the exact folder is simpler and matches the published docs; recorded in §7.

## 5. Entitlements and build mechanics

Edmund has no Xcode project, so CotEditor's xcconfig layer becomes files plus
`build-app.sh` arguments:

- **`Edmund.entitlements`** (App Store): `com.apple.security.app-sandbox`,
  `com.apple.security.files.user-selected.read-write`,
  `com.apple.security.print`. No `network.client` until crash reporting or
  another network feature actually ships. CotEditor's
  `files.user-selected.executable` is omitted; Edmund has no feature that
  needs it.
- **`Edmund-Sparkle.entitlements`** (GitHub build): the above plus
  `network.client` and the two mach-lookup exceptions
  `com.i7t5.edmund-spks` / `com.i7t5.edmund-spki`.
- **`build-app.sh` grows a variant argument** (`--variant adhoc|sparkle|mas`,
  default `adhoc` which keeps today's behavior: no entitlements, Sparkle
  embedded). `sparkle` and `mas` pass `--entitlements <file>` to the final
  `codesign` call; `mas` also skips the Sparkle embedding block and strips
  the `SU*` keys from the copied Info.plist.
- **Compile flags**: SPM cannot switch defines per invocation from
  `Package.swift` cleanly, so `build-app.sh` passes them:
  `swift build -Xswiftc -DSPARKLE` for the `sparkle` variant (and today's
  default), nothing for `mas`. Updater code in `main.swift` moves under
  `#if SPARKLE`. A separate `-DSANDBOX` flag gates the bookmark machinery in
  the path-provider seam.
- **Info.plist**: add `LSApplicationCategoryType`
  (`public.app-category.productivity`) unconditionally.
- **Signing reality check**: the sandbox itself works with ad-hoc signing,
  so every stage below is locally testable (the container appears at
  `~/Library/Containers/com.i7t5.edmund/`). Developer ID notarization for
  the Sparkle build and App Store Connect distribution need real
  certificates and are outside the repo's scope.

## 6. Staged plan

Each stage is a standalone future task; none is started.

- **Stage SB0: path-provider seam.** Collapse the duplicated `~/.edmund`
  computations (`Log.swift`, `AppSettings.logDirectory`) into one provider.
  Identical to extensibility Stage 1's prerequisite; whichever effort runs
  first builds it. Pure refactor, unit-testable, no behavior change.
- **Stage SB1: first sandboxed build.** Add the two entitlements files,
  `LSApplicationCategoryType`, and the `--variant` plumbing in
  `build-app.sh`. Build with sandbox on, then run a manual smoke checklist:
  open, edit, save, autosave, rename, move, print/PDF export, read mode,
  relative and absolute images, wiki links, logging, and the
  preferences-migration question from §3. Record every breakage in this doc.
  Nothing ships from this stage; it exists to turn §3's predictions into
  observed facts.
- **Stage SB2: the `~/.edmund` bookmark.** Implement §4 behind `-DSANDBOX`:
  bookmark persistence, launch-time resolution, container fallback for
  logs. Interim UI is a "Grant Access…" button in Settings until onboarding
  exists.
- **Stage SB3: folder grants for documents.** The per-folder prompt and
  bookmark store for sibling images and wiki links, plus graceful
  degradation for absolute paths. This is the stage with real UX surface;
  design the prompt copy with the onboarding work.
- **Stage SB4: App Store variant.** `#if SPARKLE` exclusion, MetricKit or
  removal for the crash reporter, the preferences-migration answer, real
  signing, App Store Connect, review. Blocked on SB1 through SB3 and on
  actual certificates.

## 7. Open decisions

| Decision | Options | Leaning |
|---|---|---|
| Sibling-image access UX | per-folder grant prompt / per-document bookmarks / let them break | per-folder grant (§3) |
| Dev (ad-hoc) build sandboxed? | yes, CotEditor-style / no, keep repro tooling alive | no; sandbox testing is an explicit variant (§3, ReproScript) |
| Crash reporter under sandbox | MetricKit rewrite / delete the feature | undecided; feature is dormant anyway |
| Preferences migration | automatic (verify) / explicit importer | verify in SB1 before deciding |
| Grant target | exactly `~/.edmund` / any user-chosen folder | exactly `~/.edmund` |
| iCloud documents | adopt CotEditor's entitlements / defer | defer |
