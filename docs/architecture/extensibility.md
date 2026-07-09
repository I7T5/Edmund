# Extensibility: themes & extensions design

The design-of-record for Edmund's themes/extensions model. **This is a
design doc, not an implementation.** `../ARCHITECTURE.md` documents what
exists on `main` and gets no new section here until code lands (the
same-PR rule). Everything below builds on the extension foundation that
already exists on the unmerged branch `feat/extensions-registry-and-tab`;
nothing here proposes a greenfield system.

## 1. Vision & model

Adopt the VSCode/Obsidian user-directory model: a per-user directory
(`~/.edmund/`) holds user-managed content, distinct from the app bundle and
from UserDefaults. Concretely: `~/.edmund/themes/` for theme files
(greenfield: `~/.edmund/` today holds only `logs/`, created by
`Log.swift`). Settings *choices* (which theme is active, feature toggles)
stay in UserDefaults, as they do today; only theme/extension *content* moves
to disk.

**The full v2.0.0 vision** is recorded here, not designed, from the
maintainer's own `misc/extensions.md`: a GUI theme preview/editor; a script
that converts VSCode themes to Edmund themes; an "Advanced Theme" extension
carrying the fine-grained knobs deferred out of core theming (see §3); and a
marketplace. None of this is scoped or scheduled by this doc. It's recorded
so the near-term design (§3-§5) doesn't paint itself into a corner.

**ROADMAP's "primitive marketplace"** is defined here as: a curated index
file in a repo, mapping extension IDs to their own repos/release assets, with
a download-or-move install and no server component, the shape
`obsidianmd/obsidian-releases` uses. This precedent is already cited in
`EdmundExtension.swift` on the branch (`ExtensionRegistry`'s doc comment),
independently arrived at before this design doc, which is a good sign the
shape fits.

## 2. Current state (verified against source)

**On `main`:**

- `EditorTheme` (`Sources/EdmundCore/Model/EditorTheme.swift`) is the entire
  themeable surface today: 4 color hexes (`linkBlueHex`, `codeHex`,
  `mathOperatorHex`, `mathNumberHex`) plus fonts (body + monospace, sizes,
  ligature flags) and spacing (line spacing, paragraph spacing before). One
  wrinkle: `linkBlueHex` is force-reset to the default on every `load()`:
  "the accent color is not user-customizable" (a comment left from a removed
  in-app accent picker), so it's currently *not* actually themeable despite
  living in the struct.
- Hardcoded colors live **outside** `EditorTheme` in several places: the
  selection highlight is `.systemOrange.withAlphaComponent(0.3)`
  (`EditorTextView.swift`), the `==mark==` highlight background is
  `.systemYellow.withAlphaComponent(0.3)` (two call sites in
  `+Rendering.swift`), the inline-code background is
  `NSColor(calibratedWhite: 0.5, alpha: 0.1)`, and the blockquote left bar
  uses `.tertiaryLabelColor`. Foreground/background/caret colors use system
  semantic `NSColor`s (so they already track light/dark and accent
  automatically; no theme plumbing needed for those).
- **Three consumers branch on dark mode independently**: the editor's own
  `NSColor` palette (system semantic colors resolve automatically; hardcoded
  ones don't), `HTMLTheme.css(_:callouts:dark:...)`
  (`Export/HTMLTheme.swift`) picks its own light/dark hex pairs for
  background/foreground/rule/code-background, and `CodeSyntaxPalette`
  (`Parsing/CodeSyntaxPalette.swift`) holds two complete hex tables,
  Tomorrow (light) and One Dark (dark), for 6 `CodeHighlighter.TokenType`
  values (`keyword`, `type`, `string`, `number`, `comment`, `function`) plus
  the untokenized-text color. Nothing forces these three to agree except
  discipline; see §6 for why that's a risk.
- `Callout.style(for:overrides:)` already accepts an `overrides:
  [String: CalloutStyle]` dictionary, an existing seam a future theme layer
  can hand a resolved override map into, with no signature change needed.
- **Two UserDefaults key conventions coexist**: `AppSettings.Key` uses
  dotted, namespaced strings (`"settings.appearance.mode"`,
  `"settings.general.diagnosticLogging"`); `EditorTheme`'s private `Keys`
  enum uses flat legacy names (`"EditorFontName"`, `"EditorLinkBlueHex"`).
  Any new theme/extension setting has to pick a side (or unify them, see
  §5 Stage 1).

**On `feat/extensions-registry-and-tab`** (unmerged; verified via `git show
feat/extensions-registry-and-tab:<path>`):

- `Sources/EdmundCore/Extensions/EdmundExtension.swift` defines the
  `EdmundExtension` protocol (`@MainActor`): identity (`id`, `name`,
  `summary`, `version`), state (`isInstalled`, `download()`, `uninstall()`),
  the one capability the app exposes today (`mathRenderer: MathRenderer?`),
  and Settings-display-only metadata (`developer`, `repositoryURL`,
  `installedSizeDescription`, `lastUpdated`, `downloadCount`,
  `longDescriptionURL`, `donateURL`, `hasUpdate`). The protocol's own doc
  comment is explicit that this is **not** a third-party code-loading
  mechanism: "that would mean running arbitrary code against
  storage/undo/the TextKit 2 stack, a separate, much larger
  security/sandboxing project." `ExtensionRegistry.all` is a static array
  (today: just `AdvancedMathExtension.shared`), not a fetched registry.
- `AdvancedMathExtension` wraps `RaTeXRenderer` / `RaTeXInstaller` /
  `WasmMathHost` (all under `Sources/EdmundCore/Math/RaTeX/`):
  `RaTeXInstaller` downloads a pinned `.tar.gz` release archive, SHA-256-
  verifies it **before** unpacking (a corrupted/tampered archive is never
  installed), and installs atomically into
  `~/Library/Application Support/Edmund/Math/ratex-<version>/`, a
  version-stamped path, so a new pinned version installs fresh alongside (or
  instead of) the old one. A `.verified-sha256` stamp file lets a relaunch
  skip re-downloading without re-hashing every unpacked file (the trust
  boundary is the verified download, not a per-launch re-check). A failure
  at any step leaves `state == .failed` and the renderer not-ready;
  `MathRendering` falls back to SwiftMath rather than crashing.
- `Sources/edmd/Settings/ExtensionsSettingsView.swift` is the Settings pane
  (sidebar/detail split, enable/disable toggle, install-size/version/
  download-count display) that lists `ExtensionRegistry.all`.
- This is **the foundation**: the design in §4-§5 extends this registry and
  Settings pane; it never replaces them.

## 3. Themes design

Two kinds, matching `misc/extensions.md`'s own split:

- **Editor theme**: a palette (foreground, background, secondary, caret,
  selection, checkbox) plus fonts. An optional "use system accent" flag lets
  caret/selection/checkbox track the user's system accent color instead of a
  fixed value (mirroring how `EditorTextView` already uses system semantic
  colors for foreground/background/caret today; see §2). Fonts are either
  agnostic (inherit whatever the editor's current standard/monospace fonts
  are) or theme-named with default sizes, so the editor can scale a
  theme-supplied font proportionally against the user's chosen size (some
  fonts read bigger/smaller at the same point size). An editor theme
  references a syntax theme by name.
- **Syntax theme**: the 6 `CodeHighlighter.TokenType` colors (§2) as a named,
  swappable set that replaces today's two hardcoded tables
  (`CodeSyntaxPalette`) with data.

**JSON schema sketch** (both kinds; decision 6 fixes the format as JSON):

```json
{
  "name": "My Editor Theme",
  "syntaxTheme": "my-syntax-theme",
  "useSystemAccent": true,
  "colors": {
    "foreground": { "light": "#1a1a1a", "dark": "#e6e6e6" },
    "background": { "light": "#ffffff", "dark": "#1e1e1e" },
    "secondary":  { "light": "#6a6a6a", "dark": "#9a9a9a" },
    "caret":      { "light": "#3366E6", "dark": "#5c8dff" },
    "selection":  { "light": "#ff9500", "dark": "#ff9500" },
    "checkbox":   { "light": "#3366E6", "dark": "#5c8dff" }
  },
  "fonts": { "body": null, "monospace": null }
}
```

```json
{
  "name": "My Syntax Theme",
  "colors": {
    "plain":    { "light": "#4d4d4c", "dark": "#abb2bf" },
    "keyword":  { "light": "#8959a8", "dark": "#c678dd" },
    "type":     { "light": "#c18401", "dark": "#e5c07b" },
    "string":   { "light": "#718c00", "dark": "#98c379" },
    "number":   { "light": "#f5871f", "dark": "#d19a66" },
    "comment":  { "light": "#8e908c", "dark": "#5c6370" },
    "function": { "light": "#4271ae", "dark": "#61afef" }
  }
}
```

Every color key is a `{"light": "#…", "dark": "#…"}` pair, **resolved at
draw/CSS-generation time, never at load.** Appearance switches (system
dark-mode toggle, mid-session) must not go stale, the same reason
`EditorTheme.load()` doesn't bake in an appearance today.

**Discovery**: scan `~/.edmund/themes/*.json` at launch and whenever
Settings opens. No file-watching in v1 (matches the "no speculative
flexibility" guidance; add it only if users actually edit theme files while
the app is running and file a complaint). An invalid file is skipped and
logged to `~/.edmund/logs` (the existing `Log` facility), never a crash. A
missing/invalid *selection* falls back to a built-in default theme that
ships in the app binary, not on disk, so a corrupted or deleted theme
directory can never leave the editor without a valid theme.

Theme *choice* (which theme is active) persists in UserDefaults, matching
every other setting; theme *content* (the palette itself) lives on disk in
`~/.edmund/themes/`.

Fine-grained knobs are explicitly deferred to the v2.0.0 "Advanced Theme"
extension per the maintainer's own scoping in `misc/extensions.md`:
highlight/link/inline-code/checkbox/blockquote/callout colors beyond the
core palette, padding and width tweaks, custom bullets, image framing. Note
`Callout.style(for:overrides:)` (§2) as this extension's natural first
client: the override-dict seam already exists.

## 4. Extensions design

**Split-by-kind homes** (maintainer decision, already made): user-managed
files live under `~/.edmund/extensions/<id>/` with a `manifest.json` (id,
name, version, minimum-Edmund-version, kind); machine-managed *verified
payloads* stay under Application Support, version-stamped, following the
RaTeX precedent exactly (§2). `RaTeXInstaller` doesn't move.

**Distribution**: on the GitHub build, an extension's payload is a runtime
download from a GitHub release asset (as RaTeX already does). On an App
Store build, downloaded code may run only when Apple's WebKit or
JavaScriptCore executes it (App Review guideline 2.5.2). WASM payloads such
as RaTeX satisfy that, so they runtime-download on **both** builds
(decided 2026-07-09; JIT and path caveats in
[`sandboxing.md`](sandboxing.md) §3). Payload kinds JavaScriptCore cannot
execute fall back to a manual download-and-move (the user downloads a
release asset and drops it into `~/.edmund/extensions/`). All paths
converge on "a folder appears in the
right place with the right manifest," so the loader doesn't need to know
which build produced it.

**Sandbox-forward path-provider seam**: every place that computes
`~/.edmund/...` today does it independently: `Log.swift` (line ~158) and
`AppSettings.logDirectory` (`Sources/edmd/Settings/AppSettings.swift`)
duplicate the exact same
`FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".edmund/…")`
computation. Before adding `themes/` and `extensions/` subdirectories to
that duplication, collapse it into one path-provider seam. That seam is also
where a future sandboxed build swaps in a security-scoped bookmark (granted
during onboarding, `misc/extensions.md` already anticipates this: "I will
ask the user to grant access to `~/.edmund/` in the onboarding process")
instead of a raw `FileManager` home-directory path. One seam, one place to
swap. The full sandbox adoption plan (entitlements, build
variants, the onboarding grant, per-folder document access) is
[`sandboxing.md`](sandboxing.md).

**Execution model for community extensions is OPEN.** It is deliberately
not decided by this doc. The maintainer's own uncertainty in
`misc/extensions.md` ("I know App Bundles are finicky to work with, so that
will definitely not be the recommended way for community extensions... I am
aware I need to design Edmund better for such extensions") is exactly why
this doc defers the decision to a dedicated tradeoff analysis:
`misc/native-bundle-extensions-tradeoffs.md` (gitignored, local-only, not
part of this PR; see the final summary for how to find it).

**Official roster** (extends today's registry of one):

- **Advanced Math**: exists today (§2), blocked on an upstream RaTeX
  release fixing two bugs (`aligned` row-spacing, inline-renders-as-display,
  see `misc/backlog.md`). Ships on its own release path, never through the
  main app's tag-triggered pipeline (`../ARCHITECTURE.md` §13 is explicit:
  "Never release anything through this pipeline except the main app").
- **Advanced Syntax Highlighting**: real language grammars that replace the
  heuristic `CodeHighlighter` tokenizer; the first extension to prove the
  declarative (non-code) extension path end to end (§5 Stage 4).
- **Advanced Theme**: the v2.0.0 fine-grained knobs extension from §3.

## 5. Staged implementation plan

Each stage is a future standalone task: scope, files, risks, and tests
noted so a later implementer (agent or human) can pick one up without
re-deriving this design.

- **Stage 0: color consolidation** (prerequisite for everything else).
  Move every hardcoded editor color (§2: selection orange, highlight yellow,
  inline-code background, blockquote bar) into `EditorTheme`, and make dark-
  mode resolution happen at exactly one point instead of three independently
  branching consumers. Add a parity test asserting the editor's resolved
  `NSColor` for each theme key equals `HTMLTheme`'s generated CSS hex for the
  same key, in both light and dark, the anti-drift contract that makes
  every later stage safe. Files: `EditorTheme.swift`, `EditorTextView.swift`,
  `Rendering/EditorTextView+Rendering.swift`, `Export/HTMLTheme.swift`,
  `Parsing/CodeSyntaxPalette.swift`. Risk: this touches rendering-visible
  colors across both Edit and Read mode; it needs the full visual-QA pass
  (`../ARCHITECTURE.md` §12), not just `swift test`.
- **Stage 1: theme file loading + Settings picker.** Codable schema for the
  JSON in §3; scan `~/.edmund/themes/`, validate, fall back to the built-in
  default on any error; live theme switching via the existing `applyTo…`
  broadcast pattern (`FontSettings.applyToDocuments`, which already pushes
  an updated `EditorTheme` to every open `Document.editor`, the same
  mechanism a theme picker would reuse). New picker UI in the Appearance
  pane or a new Settings pane (`SettingsWindowController.addPane`). **Open
  decision to surface, not resolve, here**: whether to unify the two
  UserDefaults key conventions (§2) as part of this stage or defer it.
  Flag it in the PR; don't decide it in this design doc.
- **Stage 2: syntax themes.** Make `CodeSyntaxPalette` data-driven from the
  loaded syntax theme instead of its two hardcoded tables; the existing
  Tomorrow/One Dark tables become the built-in default theme's data. Extend
  the Stage 0 parity test to cover token colors too.
- **Stage 3: community extension manifest + loader** (blocked on the
  execution-model decision in §4). Versioned `manifest.json` schema,
  directory scan of `~/.edmund/extensions/`, minimum-Edmund-version gate,
  enable/disable. This extends the branch's `ExtensionRegistry` and
  `ExtensionsSettingsView` rather than replacing them.
- **Stage 4: distribution + first community-facing extension.** Checksum/
  signature discipline on distributed archives that extends the SHA-256 +
  EdDSA practice already proven for RaTeX (§2) and Sparkle releases
  (`../ARCHITECTURE.md` §13). Advanced Syntax Highlighting (§4) proves the
  declarative extension path; Advanced Math re-integrates once RaTeX
  unblocks upstream.

**Open-decisions table** (collected in one place; none resolved here):

| Decision | Status |
| --- | --- |
| Community extension execution model | Open, see `misc/native-bundle-extensions-tradeoffs.md` |
| Marketplace shape | Recorded as a curated index repo (§1), not built |
| UserDefaults key-convention unification | Surfaced in Stage 1, not resolved |
| Whether `misc/extensions.md` gets a superseded-by line | The maintainer's file; his call, not edited here |

## 6. Honest risks

- **Three-consumer drift** is the single biggest risk to this whole design:
  editor `NSColor`s, `HTMLTheme` CSS, and `CodeSyntaxPalette` already branch
  on dark mode independently on `main` today, with nothing but discipline
  keeping them in sync. Adding user-supplied theme files without Stage 0's
  consolidation first would triple the surface a color bug can hide in.
  Stage 0 is not optional groundwork; it's the mitigation.
- **Dark-variant staleness** if a theme's colors were ever resolved at load
  instead of at draw/CSS-generation time (§3), a `EditorTheme.load()`-style
  bug (the `linkBlueHex` force-reset, §2, is exactly this class of bug
  already present once) would make a theme file appear to "not update" on
  an appearance switch until relaunch.
- **No sandbox today.** The app is ad-hoc signed, not notarized
  (`../ARCHITECTURE.md` §13), and ships no entitlements. The path-provider
  seam in §4 is future-proofing, not a currently-enforced boundary.
- **Key-convention split** (§2) will only get more expensive to unify the
  longer new settings keep picking a side arbitrarily.
- **Why executable community extensions are dangerous on this app,
  specifically**: Edmund is not sandboxed and not notarized, so any native
  code an extension loads runs with the *user's full permissions* and no
  Gatekeeper/App-Store backstop. A malicious or merely buggy community
  `.bundle` isn't contained the way it would be in a sandboxed host. This is
  the core tension `misc/native-bundle-extensions-tradeoffs.md` works
  through in full; it's why §4 leaves the execution model open rather than
  defaulting to "just let bundles load."
