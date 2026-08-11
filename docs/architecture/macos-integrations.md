# macOS integrations: Services, App Intents, Quick Look, AppleScript syntax

Expands [`../ARCHITECTURE.md`](../ARCHITECTURE.md) §6 (feature map). Covers the
OS-level entry points into Edmund added beyond `CFBundleDocumentTypes`
(double-click / Open With), and — importantly — **two limitations that are not
bugs but consequences of how Edmund is built and signed**. Read those before
assuming an integration is broken.

## 1. Why

Edmund is a native editor, so it should be reachable the native ways: from the
right-click Services menu, from Shortcuts/Spotlight, and by pressing Space on a
`.md` in Finder. Three of the four pieces reuse code that already exists — the
Quick Look preview in particular is the app's own `ReadModeWebView`, so a
Finder preview renders identically to Read mode with no second renderer.

## 2. The four pieces

| Piece | Files | Status |
| --- | --- | --- |
| **AppleScript code-fence syntax** | `EdmundCore/Resources/Syntaxes/applescript.json` | Works. Fully tested. |
| **Services menu** | `edmd/App/ServicesProvider.swift`, `NSServices` in `Info.plist`, registered in `main.swift` `applicationDidFinishLaunching` | Built & registered; live menu-click not yet exercised. |
| **App Intents** | `edmd/App/Intents.swift` (+ `DocumentController.newDocument(withContent:)`) | Code correct; **Shortcuts discovery blocked** — see §3. |
| **Quick Look preview** | `EdmundQuickLook` target, `Resources/QuickLookInfo.plist`, `Resources/QuickLook.entitlements`, assembled by `scripts/build-app.sh` | Live-verified and fixed 2026-08-05 — see §4. |

Shared plumbing:

- **Services** and the **App Intents** both open documents through the existing
  paths: `NSDocumentController.openDocument(withContentsOf:)` (same call the
  launch-arg open uses in `main.swift`) and a new
  `DocumentController.newDocument(withContent:)` that seeds a fresh untitled doc
  via `Document.pendingContent` (consumed in `Document.showWindows()`). One
  helper, two call sites, so they can't drift.
- **AppleScript syntax** needs no code: `SyntaxDefinitionStore.loadBundled()`
  globs `Resources/Syntaxes/*.json`, so a new language is one file. Word-list
  scopes (`keywords`/`commands`/`types`/…) must be **pairwise disjoint** — the
  scanner's "most specific wins" rule is ambiguous otherwise (a test asserts
  this).
- **Quick Look** hosts `ReadModeWebView` in a `QLPreviewingController`. The web
  view derives light/dark from `effectiveAppearance` and re-renders on a system
  appearance flip, so the preview follows System Settings ▸ Appearance for
  free. `preparePreviewOfFile(at:)` awaits the first render (via
  `onLoadFinished`) so Quick Look snapshots the finished page, not a blank one.
  Body font is `EditorTheme.quickLook` = system-ui (`HTMLTheme.cssFontStack`
  gained a `system-ui` keyword branch), rather than the editor's serif.

## 3. Limitation — App Intents don't appear in Shortcuts from a SwiftPM build

The intents compile and are correct, but **Shortcuts/Spotlight won't list them**
when the app is built with SwiftPM.

Shortcuts discovers intents from a `Metadata.appintents` bundle inside the app.
Xcode generates it in a build phase; SwiftPM has no equivalent.
`appintentsmetadataprocessor` (the tool that produces the bundle) needs per-file
`.swiftconstvalues` supplementary outputs from the Swift compiler, or it fails
with `No swift const values found … BinaryScanningError error 6`. Xcode requests
those outputs via `SWIFT_ENABLE_EMIT_CONST_VALUES`; SwiftPM does not, and
passing `-const-gather-protocols-file` alone does **not** populate the
output-file-map with const-values entries, so nothing is emitted. Confirmed
2026-07-23 against Xcode 16.2.

`build-app.sh` runs the metadata step best-effort: it prints a one-line warning
and continues, and will start succeeding automatically the day the toolchain can
emit the const values (or the app is built from an Xcode project).

**What still works:** the **Services** entries deliver the same "Open in Edmund"
/ "New Document with Selection" actions with no metadata dependency. If Shortcuts
support becomes a requirement, the fix is an Xcode-project build (or a wrapper
target), not more SwiftPM flags.

## 4. Fixed — the Quick Look appex hung (it did launch; it just never replied)

**Live-verified 2026-08-05**, by an end user on a real ad-hoc-signed
`/Applications/Edmund.app` install (macOS 26.6) — exactly the "To verify live"
scenario the prior revision of this section asked for, minus the Developer-ID
signing step. Findings correct the previous hypothesis:

**The appex does launch under ad-hoc signing from `/Applications`.**
`pluginkit -m -v` showed it `+` (enabled), the process spawned, and the
`os_log` breadcrumbs in `PreviewViewController` (`loadView`,
`preparePreviewOfFile`, `render finished`, under `subsystem ==
"com.i7t5.edmund.quicklook"`) were all present. The earlier claim that
`quicklookd` declines to launch ad-hoc-signed appexes outright does not hold
here — it may still describe the non-`/Applications` dev-copy case this
section originally tested against (never re-tested from `/Applications`
directly), but that is not what an end user's real install hits.

**The actual failure is downstream, in WKWebView.**
`Resources/QuickLook.entitlements` carried `app-sandbox` +
`files.user-selected.read-only` only. WKWebView is multi-process even for
fully local/offline HTML — its `WebContent` helper needs
`com.apple.security.network.client` just to complete its own XPC handshake
with the host process, regardless of whether the page it renders ever touches
the network. Without it, `WebContent` dies on launch every time, logged under
WebKit's own subsystem (not `PreviewViewController`'s — a broader predicate is
needed to see it):

```bash
log show --predicate 'process CONTAINS "EdmundQuickLook"' --info --debug
```

```
WebContent[0] Application does not have permission to communicate with network resources. rc=1 : errno=34
WebProcessProxy::didFinishLaunching: Invalid connection identifier (web process failed to launch)
WebProcessProxy::processDidTerminateOrFailedToLaunch: reason=Crash
```

**Why it hangs instead of falling back to plain text.** `preparePreviewOfFile`
awaits a `withCheckedContinuation` that only `webView.onLoadFinished` resumes
(§2 above). WebKit never surfaces a `WebContent` launch failure to
`ReadModeWebView` as a call to that closure, so the continuation is never
resumed and the `async throws` function never returns — Quick Look has no
fallback for an extension that never replies, so Finder just spins forever.
Confirmed with `sample <pid>`: every thread sat idle in a normal run-loop wait
(`mach_msg2_trap`), including the `WebCore: Scrolling` thread that only exists
once a `WKWebView` has actually been instantiated — nothing was blocked on a
lock or syscall, because nothing was running at all. The failure had already
happened; nothing was ever told to resume.

**Fix:** add `com.apple.security.network.client` to
`Resources/QuickLook.entitlements`. Verified: after re-signing and
re-registering, the same `qlmanage -p` invocation shows `WebContent` launching
successfully and the page completing (`didFinishLoadForFrame`,
`DidFirstMeaningfulPaint`), no permission error.

**Follow-up worth considering, not part of this fix:** the continuation in
`preparePreviewOfFile` has no timeout or `didFail` path, so any *other* future
cause of a `WebContent` launch or load failure reproduces this exact hang.
Resuming (and throwing) on a navigation failure, or adding a timeout, would
make a future break fail fast instead of hanging forever again.

### Signing order in `build-app.sh` (why it's the way it is)

The appex is sealed inside the app, so it must be signed **before** the app, and
the app must be sealed **without** `--deep` — a `--deep` outer sign re-signs
every nested item with default flags, which strips the appex's sandbox
entitlements and resets its identifier to the app's. So: sign
`Sparkle.framework` (deep, for its own XPC helpers) → sign the appex with its
entitlements → seal the `.app` non-deep over the already-signed contents. The
appex's resource bundles go in `Contents/Resources` *before* signing (an appex's
`Bundle.module` resolves via `Bundle.main.resourceURL`), unlike the app's
SwiftMath bundle which must sit at the `.app` root *after* the seal.

## 5. Not built (candidates)

- **App `.sdef` scripting dictionary** — real `tell application "Edmund" to …`
  automation; the one surface App Intents can't cover. Distinct from §2's
  AppleScript *highlighting*.
- **Conversion intents** — "Markdown to HTML/PDF" reusing `MarkdownPrinter` /
  `DocumentHTML`; cheap once §3's metadata plumbing works.
- **`UTImportedTypeDeclarations`** — declare `net.daringfireball.markdown`
  properly (consistent Finder kind string + doc icon); also modernizes the
  legacy `CFBundleTypeExtensions` block. Pure `Info.plist`.
- **CLI symlink**, **Dock menu** (`applicationDockMenu`), **Quick Look
  thumbnails** (`QLThumbnailProvider`, same appex).
