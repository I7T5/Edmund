// AppSettings — UserDefaults-backed model for every Settings value.
// The rest of the app reads these accessors; the SwiftUI panes bind to the
// same keys via @AppStorage.

import AppKit
import EdmundCore

enum AppSettings {
    enum StartupAction: String, CaseIterable, Identifiable {
        case createNewDocument
        case doNothing
        var id: Self { self }
        var label: String {
            switch self {
            case .createNewDocument: return "Create New Document"
            case .doNothing: return "Do Nothing"
            }
        }
    }


    enum AppearanceMode: String, CaseIterable, Identifiable {
        case matchSystem
        case light
        case dark
        var id: Self { self }
        var label: String {
            switch self {
            case .matchSystem: return "Match System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }
        /// Display order in the Appearance pane (left to right).
        static let displayOrder: [AppearanceMode] = [.light, .dark, .matchSystem]
    }

    /// What one indent unit is made of. The width (in spaces) is `indentWidth`;
    /// a tab indent is always one tab character regardless of the width.
    enum IndentStyle: String, CaseIterable, Identifiable {
        case spaces
        case tabs
        var id: Self { self }
        var label: String {
            switch self {
            case .spaces: return "Spaces"
            case .tabs: return "Tabs"
            }
        }
    }

    /// How long diagnostic logs are kept before being pruned on launch.
    enum LogRetention: String, CaseIterable, Identifiable {
        case oneDay, twoDays, oneWeek, twoWeeks, thirtyDays, never
        var id: Self { self }
        var label: String {
            switch self {
            case .oneDay: return "1 day"
            case .twoDays: return "2 days"
            case .oneWeek: return "1 week"
            case .twoWeeks: return "2 weeks"
            case .thirtyDays: return "30 days"
            case .never: return "Never"
            }
        }
        /// The retention window in seconds; `nil` means keep forever.
        var timeInterval: TimeInterval? {
            let day: TimeInterval = 24 * 60 * 60
            switch self {
            case .oneDay: return day
            case .twoDays: return 2 * day
            case .oneWeek: return 7 * day
            case .twoWeeks: return 14 * day
            case .thirtyDays: return 30 * day
            case .never: return nil
            }
        }
    }

    enum Key {
        static let reopenWindows = "settings.general.reopenWindows"
        // Must match Sparkle's own default key exactly — Sparkle reads/writes this string.
        static let automaticallyChecksForUpdates = "SUAutomaticallyChecksForUpdates"
        static let startupAction = "settings.general.startupAction"
        static let autoSaveWithVersions = "settings.general.autoSaveWithVersions"
        static let quitWhenAllWindowsClosed = "settings.general.quitWhenAllWindowsClosed"
        static let appearanceMode = "settings.appearance.mode"
        static let maxContentWidthCm = "settings.appearance.maxContentWidthCm"
        // "cm" / "in" override the locale default for the content-width control.
        static let contentWidthUnit = "settings.appearance.contentWidthUnit"
        // Settings ▸ Themes. Which theme is active in each of the four slots —
        // two kinds (editor chrome, code syntax) × two appearances. Values are
        // ThemeStore theme names; an unknown one falls back to the built-in.
        static let themeGeneralLight = "settings.themes.generalLight"
        static let themeGeneralDark  = "settings.themes.generalDark"
        static let themeSyntaxLight  = "settings.themes.syntaxLight"
        static let themeSyntaxDark   = "settings.themes.syntaxDark"
        /// The font preset in force. Named `settings.themes.*` for continuity
        /// with the four above and because `ThemeStore` loads it; it is chosen
        /// in Appearance, and no color theme names it.
        static let themeFont         = "settings.themes.font"
        // Whether the "Fonts by script" section at the foot of the Appearance
        // pane is expanded (per-script cascade rows).
        static let fontsByScriptExpanded = "settings.appearance.fontsByScriptExpanded"
        static let suppressInconsistentLineEndingWarning = "settings.general.suppressInconsistentLineEndingWarning"
        static let diagnosticLogging = "settings.general.diagnosticLogging"
        static let verboseEditorDiagnostics = "settings.advanced.verboseEditorDiagnostics"
        static let blockExternalImages = "settings.advanced.blockExternalImages"
        static let logRetention = "settings.general.logRetention"
        static let renderBlankLinesAsBreaks = "settings.reading.renderBlankLinesAsBreaks"
        static let sourceMode = "settings.view.sourceMode"
        static let enabledExtensionIDs = "settings.extensions.enabledIDs"
        static let sendCrashLogs = "settings.advanced.sendCrashLogs"
        static let sentCrashReports = "settings.advanced.sentCrashReports"
        static let lastWindowWidth  = "settings.window.lastWidth"
        static let lastWindowHeight = "settings.window.lastHeight"
        // Syntax feature toggles (all default on). Read into `markdownFeatures`.
        // Master switch: off → every non-GFM extension is disabled at once.
        // The GFM callout alerts (NOTE/TIP/…) have no toggle — always on.
        static let enableNonGFM      = "settings.syntax.enableNonGFM"
        static let synFrontMatter    = "settings.syntax.frontMatter"
        static let synMath           = "settings.syntax.math"
        static let synHighlight      = "settings.syntax.highlight"
        static let synComment        = "settings.syntax.comment"
        static let synWikilink       = "settings.syntax.wikilink"
        static let synTag            = "settings.syntax.tag"
        static let synBlockRef       = "settings.syntax.blockRef"
        static let synFootnote       = "settings.syntax.footnote"
        static let synObsidianCallout = "settings.syntax.obsidianCallout"
        // The language a fenced code block with no info string is highlighted as.
        // "plain" = no highlighting. Consumed by the code-block highlighter.
        static let defaultCodeSyntax = "settings.syntax.defaultCodeSyntax"
        // Edit ▸ Display.
        static let showToolbar         = "settings.edit.showToolbar"
        static let showFormatBar       = "settings.edit.showFormatBar"
        static let autoHideToolbar     = "settings.edit.autoHideToolbar"
        static let showInvisibles      = "settings.edit.showInvisibles"
        // Parked with the rest of the Always mode (see `showInvisibles` below):
        // static let invisiblesMode  = "settings.edit.invisiblesMode"
        static let invisibleLineEnding = "settings.edit.invisibleLineEnding"
        static let invisibleTab        = "settings.edit.invisibleTab"
        static let invisibleSpace      = "settings.edit.invisibleSpace"
        static let invisibleWhitespace = "settings.edit.invisibleWhitespace"
        static let invisibleControl    = "settings.edit.invisibleControl"
        static let showListIndentGuides = "settings.edit.showListIndentGuides"
        static let showLineNumbers     = "settings.edit.showLineNumbers"
        // The same key the View menu's Typewriter Mode item writes
        // (AppDelegate.typewriterModeKey), so the two stay in sync.
        static let typewriterMode      = "EditorTypewriterMode"
        static let focusMode           = "settings.edit.focusMode"
        // Edit ▸ Editing.
        static let indentStyle         = "settings.edit.indentStyle"
        static let indentWidth         = "settings.edit.indentWidth"
        static let detectIndent        = "settings.edit.detectIndent"
        static let strictLineBreaks    = "settings.edit.strictLineBreaks"
        static let hardWrapLongLines   = "settings.edit.hardWrapLongLines"
        static let autoCloseBrackets   = "settings.edit.autoCloseBrackets"
        static let continueLists       = "settings.edit.continueLists"
        static let spellCheck          = "settings.edit.spellCheck"
        static let grammarCheck        = "settings.edit.grammarCheck"
    }

    /// The default language for untagged code fences ("plain" = none).
    static var defaultCodeSyntax: String {
        get { UserDefaults.standard.string(forKey: Key.defaultCodeSyntax) ?? "plain" }
        set { UserDefaults.standard.set(newValue, forKey: Key.defaultCodeSyntax) }
    }

    /// A bool defaulting to `true` until the user explicitly clears it (the
    /// "opt-out" idiom used by the markdown toggles and several others).
    static func boolDefaultTrue(_ key: String) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else { return true }
        return UserDefaults.standard.bool(forKey: key)
    }

    /// The enabled Markdown extensions, assembled from the per-feature Settings
    /// toggles. Pushed into every open `EditorTextView.markdownFeatures` and used
    /// to build `ReadRenderOptions`, so Edit and Read agree. Features with no
    /// toggle UI yet (Phase 2: front matter, tags, block refs, multi-block
    /// comments) stay on so nothing regresses before their settings land.
    static var markdownFeatures: MarkdownFeatures {
        // The 5 GFM callout alerts are core GFM — always on, no toggle.
        var f: MarkdownFeatures = [.callout]

        // Master switch off → plain CommonMark/GFM (GFM callout alerts survive).
        guard boolDefaultTrue(Key.enableNonGFM) else { return f }

        // Non-GFM syntax with no grid toggle of its own is master-direct:
        // ordinary image dimensions `![alt|200](url)` aren't tied to any grid item.
        f.insert(.imageDimensions)

        // The 5x2 grid. Related sub-syntaxes fold into their grid toggle:
        // wikilink image embeds under Wikilink, collapsible under the Obsidian
        // callout, multi-block comments under Comment.
        if boolDefaultTrue(Key.synFrontMatter)    { f.insert(.frontMatter) }
        if boolDefaultTrue(Key.synMath)           { f.insert(.math) }
        if boolDefaultTrue(Key.synHighlight)      { f.insert(.highlight) }
        if boolDefaultTrue(Key.synComment)        { f.formUnion([.inlineComment, .multiBlockComment]) }
        if boolDefaultTrue(Key.synWikilink)       { f.formUnion([.wikilink, .wikilinkEmbed]) }
        if boolDefaultTrue(Key.synTag)            { f.insert(.tag) }
        if boolDefaultTrue(Key.synBlockRef)       { f.insert(.blockRef) }
        if boolDefaultTrue(Key.synFootnote)       { f.insert(.footnote) }
        if boolDefaultTrue(Key.synObsidianCallout) { f.formUnion([.calloutExtendedTypes, .collapsibleCallout]) }
        return f
    }

    /// Maximum text-column width in centimetres. Wider windows center the
    /// column at this physical width; narrower windows fill edge-to-edge.
    /// Default: a comfortable 12 cm / 5 in reading column.
    static var maxContentWidthCm: Double {
        get {
            guard UserDefaults.standard.object(forKey: Key.maxContentWidthCm) != nil else {
                return defaultMaxContentWidthCm
            }
            return UserDefaults.standard.double(forKey: Key.maxContentWidthCm)
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.maxContentWidthCm) }
    }

    /// Out-of-the-box reading column: 5 in for US locales, 12 cm elsewhere.
    /// This is also the slider's magnetic snap point.
    static var defaultMaxContentWidthCm: Double {
        Locale.current.measurementSystem == .us ? 5.0 * 2.54 : 12.0
    }

    /// Full frame size of the last document window, to reopen new windows at the
    /// same dimensions (applied via setFrame). Returns nil when nothing is saved.
    /// The floor only rejects garbage/zero values — every real window size,
    /// including ones smaller than the default, is remembered.
    static var lastWindowSize: NSSize? {
        get {
            let w = UserDefaults.standard.double(forKey: Key.lastWindowWidth)
            let h = UserDefaults.standard.double(forKey: Key.lastWindowHeight)
            guard w >= 100, h >= 100 else { return nil }
            return NSSize(width: w, height: h)
        }
        set {
            guard let s = newValue else { return }
            UserDefaults.standard.set(Double(s.width),  forKey: Key.lastWindowWidth)
            UserDefaults.standard.set(Double(s.height), forKey: Key.lastWindowHeight)
        }
    }

    static var reopenWindows: Bool {
        get { UserDefaults.standard.bool(forKey: Key.reopenWindows) }
        set { UserDefaults.standard.set(newValue, forKey: Key.reopenWindows) }
    }

    /// Source mode: an alternate form of Edit mode that shows the raw markdown.
    /// When on, the editing half of the view-mode toggle is Source instead of
    /// Edit (so the toggle flips Source ↔ Read). Defaults off.
    static var sourceMode: Bool {
        get { UserDefaults.standard.bool(forKey: Key.sourceMode) }
        set { UserDefaults.standard.set(newValue, forKey: Key.sourceMode) }
    }

    /// Read mode: render runs of blank lines as proportional vertical space
    /// (preserving the author's spacing). Defaults on. The toggle UI lives in a
    /// future Reading-settings tab; the value is already honored here.
    static var renderBlankLinesAsBreaks: Bool {
        get {
            guard UserDefaults.standard.object(forKey: Key.renderBlankLinesAsBreaks) != nil else {
                return true
            }
            return UserDefaults.standard.bool(forKey: Key.renderBlankLinesAsBreaks)
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.renderBlankLinesAsBreaks) }
    }

    static var startupAction: StartupAction {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Key.startupAction),
                  let action = StartupAction(rawValue: raw) else {
                return .createNewDocument
            }
            return action
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.startupAction) }
    }

    static var autoSaveWithVersions: Bool {
        get {
            guard UserDefaults.standard.object(forKey: Key.autoSaveWithVersions) != nil else {
                return true
            }
            return UserDefaults.standard.bool(forKey: Key.autoSaveWithVersions)
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.autoSaveWithVersions) }
    }

    /// Autosave interval for the "elsewhere" backup AppKit keeps when Auto Save with
    /// Versions is off — a recovery copy in ~/Library/Autosave Information/ that it
    /// offers back after an unexpected quit, without ever touching the document or
    /// the version store. TextEdit behaves the same way. Zero is AppKit's "no timer"
    /// value: with autosave-in-place on, it drives its own change-count schedule.
    static var autosavingDelay: TimeInterval { autoSaveWithVersions ? 0 : 30 }

    /// Pushes the autosave interval into the document controller. Called at launch
    /// and whenever the Auto Save toggle changes.
    @MainActor
    static func applyAutosaving() {
        NSDocumentController.shared.autosavingDelay = autosavingDelay
    }

    /// Whether closing the last window quits the app. Off by default, the way
    /// most document apps behave — the app stays running and File ▸ New reopens
    /// a window. Mutually exclusive with `reopenWindows` (see GeneralSettingsView).
    static var quitWhenAllWindowsClosed: Bool {
        get { UserDefaults.standard.bool(forKey: Key.quitWhenAllWindowsClosed) }
        set { UserDefaults.standard.set(newValue, forKey: Key.quitWhenAllWindowsClosed) }
    }

    static var appearanceMode: AppearanceMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Key.appearanceMode),
                  let mode = AppearanceMode(rawValue: raw) else {
                return .matchSystem
            }
            return mode
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.appearanceMode) }
    }

    /// IDs of extensions (`EdmundExtension.id`) the user has turned on.
    static var enabledExtensionIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Key.enabledExtensionIDs) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Key.enabledExtensionIDs) }
    }

    static func isExtensionEnabled(_ id: String) -> Bool { enabledExtensionIDs.contains(id) }

    /// Persists an extension's on/off state and re-applies the live wiring.
    @MainActor static func setExtensionEnabled(_ id: String, _ enabled: Bool) {
        var ids = enabledExtensionIDs
        if enabled { ids.insert(id) } else { ids.remove(id) }
        enabledExtensionIDs = ids
        applyExtensionStates()
    }

    /// Wires enabled extensions into the app's live state: whether "Advanced
    /// Math" is enabled decides `MathRendering.shared.alternate` (RaTeX vs.
    /// falling back to SwiftMath), and whether "Mermaid" is enabled decides
    /// whether `MermaidRenderer.shared` will render diagrams at all. On-screen
    /// content restyles via `.renderEngineChanged`. Called at launch and
    /// whenever an extension is enabled/disabled in Settings.
    @MainActor static func applyExtensionStates() {
        let mathExt = AdvancedMathExtension.shared
        if isExtensionEnabled(mathExt.id) {
            MathRendering.shared.alternate = mathExt.mathRenderer
            // Load the (already downloaded) payload so the engine is actually
            // ready — `download()` is a fast no-op-then-load when installed, and
            // re-fetches if a previously enabled install went missing. Equations
            // restyle once it's ready. Fired here so a previously enabled RaTeX
            // comes back after relaunch, not just when toggled in Settings.
            Task {
                await mathExt.download()
                MathRendering.shared.engineDidChange()
            }
        } else {
            MathRendering.shared.alternate = nil
        }

        // Same shape for Mermaid, minus the fallback: there is no built-in
        // diagram engine to degrade to, so "disabled" simply means the fenced
        // block stays a code block.
        let mermaidExt = MermaidExtension.shared
        MermaidRenderer.shared.isEnabled = isExtensionEnabled(mermaidExt.id)
        if MermaidRenderer.shared.isEnabled {
            Task {
                await mermaidExt.download()
                NotificationCenter.default.post(name: .renderEngineChanged, object: nil)
            }
        }

        MathRendering.shared.engineDidChange()
    }

    static var suppressInconsistentLineEndingWarning: Bool {
        get { UserDefaults.standard.bool(forKey: Key.suppressInconsistentLineEndingWarning) }
        set { UserDefaults.standard.set(newValue, forKey: Key.suppressInconsistentLineEndingWarning) }
    }

    /// Whether diagnostic logging is on. Defaults to off; the user can opt in.
    static var diagnosticLogging: Bool {
        get { UserDefaults.standard.bool(forKey: Key.diagnosticLogging) }
        set { UserDefaults.standard.set(newValue, forKey: Key.diagnosticLogging) }
    }

    /// Verbose editor tracing: high-volume per-edit / per-caret-move trace lines
    /// for diagnosing live-NSTextView / TextKit 2 editor bugs (caret drift, sync
    /// desyncs) that can't be reproduced headlessly. Off by default — turned on
    /// only when capturing a reproduction. Requires diagnostic logging to be on.
    static var verboseEditorDiagnostics: Bool {
        get { UserDefaults.standard.bool(forKey: Key.verboseEditorDiagnostics) }
        set { UserDefaults.standard.set(newValue, forKey: Key.verboseEditorDiagnostics) }
    }

    /// Whether Read mode / export blocks remote (`http`/`https`) image loads.
    /// Defaults on: no surprise network requests until the user opts out.
    static var blockExternalImages: Bool {
        get {
            guard UserDefaults.standard.object(forKey: Key.blockExternalImages) != nil else {
                return true
            }
            return UserDefaults.standard.bool(forKey: Key.blockExternalImages)
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.blockExternalImages) }
    }

    /// Whether to auto-send crash reports on launch. Opt-in: defaults off, since
    /// it sends data off-device. (UI currently commented out — see
    /// AdvancedSettingsView — until the receiving server exists.)
    static var sendCrashLogs: Bool {
        get { UserDefaults.standard.bool(forKey: Key.sendCrashLogs) }
        set { UserDefaults.standard.set(newValue, forKey: Key.sendCrashLogs) }
    }

    /// Filenames of crash reports already uploaded, so we don't resend them.
    /// Bounded on write by dropping entries whose `.ips` file no longer exists.
    static var sentCrashReports: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Key.sentCrashReports) ?? []) }
        set {
            let onDisk = (try? FileManager.default.contentsOfDirectory(
                atPath: CrashReporter.diagnosticReportsDirectory.path)).map(Set.init) ?? []
            let pruned = onDisk.isEmpty ? newValue : newValue.intersection(onDisk)
            UserDefaults.standard.set(Array(pruned), forKey: Key.sentCrashReports)
        }
    }

    static var logRetention: LogRetention {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Key.logRetention),
                  let value = LogRetention(rawValue: raw) else {
                return .twoWeeks
            }
            return value
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.logRetention) }
    }

    /// Where diagnostic logs live (see `Log.defaultDirectory`).
    static var logDirectory: URL { Log.defaultDirectory }

    /// Pushes the current logging settings into the `Log` facility. Called at
    /// launch and whenever the toggle or retention changes.
    static func applyLogging() {
        Log.configure(enabled: diagnosticLogging,
                      directory: logDirectory,
                      retention: logRetention.timeInterval)
        Log.setVerbose(verboseEditorDiagnostics)
    }

    /// Pushes the default code-block language into the shared definition store and
    /// reloads bundled + user (Application Support/Edmund/Syntaxes) definitions. Called at launch,
    /// and after the popup changes or a def is imported/removed.
    static func applyCodeSyntax() {
        SyntaxDefinitionStore.shared.defaultLanguage = defaultCodeSyntax
        SyntaxDefinitionStore.shared.reload()
    }

    // MARK: - Themes pane

    /// The active theme name for a slot, or the built-in when unset. The
    /// defaults live in `ThemeStore`, not here, so Core still works standalone
    /// (Quick Look, tests) with no settings to read.
    static func themeName(_ key: String, default fallback: String) -> String {
        UserDefaults.standard.string(forKey: key) ?? fallback
    }

    /// The theme each slot holds when nothing has been chosen — and what
    /// Restore Defaults puts back. Named rather than spelled out at each use:
    /// the accessors below, the pane's `@AppStorage` defaults and the restore
    /// all have to agree, and four copies of "one-dark" is three chances to
    /// drift.
    enum DefaultTheme {
        static let generalLight = "classic-light"
        static let generalDark = "classic-dark"
        static let syntaxLight = "tomorrow"
        static let syntaxDark = "one-dark"
        /// The shipped typography, saved as a preset — picking it changes
        /// nothing, which is what makes it the one the picker starts on.
        static let font = "iowan"
    }

    static var generalThemeLight: String {
        get { themeName(Key.themeGeneralLight, default: DefaultTheme.generalLight) }
        set { UserDefaults.standard.set(newValue, forKey: Key.themeGeneralLight) }
    }
    static var generalThemeDark: String {
        get { themeName(Key.themeGeneralDark, default: DefaultTheme.generalDark) }
        set { UserDefaults.standard.set(newValue, forKey: Key.themeGeneralDark) }
    }
    static var syntaxThemeLight: String {
        get { themeName(Key.themeSyntaxLight, default: DefaultTheme.syntaxLight) }
        set { UserDefaults.standard.set(newValue, forKey: Key.themeSyntaxLight) }
    }
    static var syntaxThemeDark: String {
        get { themeName(Key.themeSyntaxDark, default: DefaultTheme.syntaxDark) }
        set { UserDefaults.standard.set(newValue, forKey: Key.themeSyntaxDark) }
    }
    static var fontTheme: String {
        get { themeName(Key.themeFont, default: DefaultTheme.font) }
        set { UserDefaults.standard.set(newValue, forKey: Key.themeFont) }
    }

    /// Gives the Appearance pane's picker a preset to name, once, for anyone
    /// arriving from a build without them.
    ///
    /// The picker has no "none" state — a preset is always in force — so a user
    /// who never touched their fonts can be pointed at the one holding the
    /// shipped values. A user who *did* has theirs in the `Editor*` keys, which
    /// the chosen preset is about to override; capture them as a preset of
    /// their own first. Dropping them onto a bundled one would change their
    /// editor on upgrade with no way back.
    ///
    /// Keyed on the setting being absent rather than a version number: that is
    /// exactly the condition, and it stays true for a user who skips releases.
    static func migrateFontThemeSelection() {
        guard UserDefaults.standard.string(forKey: Key.themeFont) == nil else { return }

        // Compared as presets so only the fields one carries count — a changed
        // accent color is no reason to seed. The names cancel.
        let probe = "probe"
        let current = EditorTheme.load().fontTheme(name: probe, displayName: probe)
        guard current != EditorTheme.default.fontTheme(name: probe, displayName: probe) else {
            fontTheme = DefaultTheme.font
            return
        }

        var name = "custom-fonts"
        var suffix = 2
        while ThemeStore.shared.kind(ofThemeNamed: name) != nil {
            name = "custom-fonts-\(suffix)"
            suffix += 1
        }
        do {
            try ThemeStore.shared.save(
                EditorTheme.load().fontTheme(name: name, displayName: "Custom"))
            fontTheme = name
        } catch {
            // The fonts stay as they were in the `Editor*` keys; only the
            // picker is left pointing at the shipped preset.
            Log.error("Seeding a font preset from the saved fonts failed: \(error)", category: .app)
            fontTheme = DefaultTheme.font
        }
    }

    /// The bundled editor themes were `default-light` / `default-dark` before
    /// they were named Classic. A stored selection still pointing at an old
    /// name resolves to nothing: the editor falls back and keeps drawing, but
    /// the sidebar shows no theme as active, which reads as broken.
    ///
    /// Renaming a *bundled* theme's `name` is normally out of bounds for
    /// exactly that reason — it is the value stored in settings — and this is
    /// the migration that buys the exception.
    static func migrateRenamedThemes() {
        let renamed = ["default-light": "classic-light", "default-dark": "classic-dark"]
        for key in [Key.themeGeneralLight, Key.themeGeneralDark] {
            guard let stored = UserDefaults.standard.string(forKey: key),
                  let now = renamed[stored] else { continue }
            UserDefaults.standard.set(now, forKey: key)
        }
    }

    /// Pushes the four active theme names into the shared store and reloads
    /// bundled + user themes. Called at launch, and after the Themes pane
    /// changes a selection or a theme file is added/removed.
    ///
    /// Reload first, then assign: `reload()` rebuilds the tables but leaves the
    /// active names alone, so assigning after it means a name that only just
    /// appeared on disk resolves on this pass rather than the next.
    static func applyThemes() {
        ThemeStore.shared.reload()
        migrateRenamedThemes()
        migrateFontThemeSelection()
        ThemeStore.shared.activeGeneralLight = generalThemeLight
        ThemeStore.shared.activeGeneralDark = generalThemeDark
        ThemeStore.shared.activeSyntaxLight = syntaxThemeLight
        ThemeStore.shared.activeSyntaxDark = syntaxThemeDark
    }

    /// Re-renders every open document after a theme change. Colors are baked
    /// into `NSAttributedString` attributes rather than resolved at draw time, so
    /// a theme swap needs the same full restyle an appearance flip does.
    @MainActor static func applyThemesToOpenDocuments() {
        applyThemes()
        for case let document as Document in NSDocumentController.shared.documents {
            guard let editor = document.editor else { continue }
            // Fonts before colors: a theme may override the font, and
            // `applyChromeColors` bakes it into `typingAttributes`.
            editor.resolveTheme()
            editor.applyChromeColors()
            editor.invisibles = invisiblesConfig
            editor.recomposeAllDirty()
            document.refreshReadView()
        }
    }

    // MARK: - Edit pane

    /// Whether document windows show their toolbar. Mirrored by the View menu's
    /// Show/Hide Toolbar item and the Edit ▸ Display checkbox.
    static var showToolbar: Bool {
        get { boolDefaultTrue(Key.showToolbar) }
        set { UserDefaults.standard.set(newValue, forKey: Key.showToolbar) }
    }

    /// Whether the toolbar hides itself in full screen (revealed by moving the
    /// pointer to the top of the screen).
    static var autoHideToolbar: Bool {
        get { boolDefaultTrue(Key.autoHideToolbar) }
        set { UserDefaults.standard.set(newValue, forKey: Key.autoHideToolbar) }
    }

    /// Whether document windows show the format bar across the top of the
    /// editor. Defaults off: it costs a strip of the window and every command
    /// on it is already on the Format menu, so it is opt-in. Mirrored by the
    /// View menu's Show Format Bar item.
    static var showFormatBar: Bool {
        get { UserDefaults.standard.bool(forKey: Key.showFormatBar) }
        set { UserDefaults.standard.set(newValue, forKey: Key.showFormatBar) }
    }

    static var indentStyle: IndentStyle {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Key.indentStyle),
                  let style = IndentStyle(rawValue: raw) else {
                return .spaces
            }
            return style
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.indentStyle) }
    }

    /// One indent unit, in spaces. Defaults to 2 — the width the editor has
    /// always used, so an existing install's indentation doesn't change.
    static var indentWidth: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: Key.indentWidth)
            return (1...8).contains(stored) ? stored : 2
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.indentWidth) }
    }

    static var autoCloseBrackets: Bool { boolDefaultTrue(Key.autoCloseBrackets) }
    static var continueLists: Bool { boolDefaultTrue(Key.continueLists) }
    static var spellCheck: Bool { UserDefaults.standard.bool(forKey: Key.spellCheck) }

    /// Strict line breaks (default on): when off, Read mode / export render each
    /// single source newline as a literal `<br>`. Read at render time (passed
    /// into `ReadRenderOptions`), not pushed onto the editor.
    static var strictLineBreaks: Bool { boolDefaultTrue(Key.strictLineBreaks) }

    /// Hard-wrap long lines (default off): a file that arrives hard-wrapped is
    /// joined into logical lines when it opens and re-wrapped at 80 columns when
    /// it is saved. Like `strictLineBreaks` this is read at load/save time
    /// (Document) rather than pushed onto the editor — there is no live editor
    /// behavior to configure.
    ///
    /// Requires strict line breaks: with those off a single newline renders as a
    /// literal `<br>`, so joining lines would delete visible breaks and wrapping
    /// would invent them. The Settings checkbox greys out to match.
    static var hardWrapLongLines: Bool {
        UserDefaults.standard.bool(forKey: Key.hardWrapLongLines) && strictLineBreaks
    }

    /// Detect and learn a document's indent style when it opens (default on).
    /// Read once at open time in `Document.showWindows`, overriding this
    /// document's indent; it never rewrites the global `indentStyle`/`indentWidth`.
    static var detectIndent: Bool { boolDefaultTrue(Key.detectIndent) }

    /// Show invisible characters (whitespace marks) within the selection —
    /// default off.
    ///
    /// Invisibles once had an Always / Upon Selection mode picker; it was cut
    /// (commit 6652972) because nobody reached for Always. Parked here, with the
    /// matching pieces in `EditSettingsView` and `InvisiblesConfig`, in case the
    /// choice comes back:
    ///
    ///     enum InvisibleCharacterMode: String, CaseIterable, Identifiable {
    ///         case uponSelection
    ///         case always
    ///         var id: Self { self }
    ///         var label: String {
    ///             switch self {
    ///             case .uponSelection: return "Upon Selection"
    ///             case .always: return "Always"
    ///             }
    ///         }
    ///     }
    ///
    ///     static var invisiblesMode: InvisibleCharacterMode {
    ///         guard let raw = UserDefaults.standard.string(forKey: Key.invisiblesMode),
    ///               let mode = InvisibleCharacterMode(rawValue: raw) else { return .uponSelection }
    ///         return mode
    ///     }
    static var showInvisibles: Bool { UserDefaults.standard.bool(forKey: Key.showInvisibles) }

    // The per-category toggles (default on, gated by `showInvisibles`).
    static var invisibleLineEnding: Bool { boolDefaultTrue(Key.invisibleLineEnding) }
    static var invisibleTab: Bool { boolDefaultTrue(Key.invisibleTab) }
    static var invisibleSpace: Bool { boolDefaultTrue(Key.invisibleSpace) }
    static var invisibleWhitespace: Bool { boolDefaultTrue(Key.invisibleWhitespace) }
    static var invisibleControl: Bool { boolDefaultTrue(Key.invisibleControl) }

    /// The invisibles config pushed onto every editor, or nil when off. The mark
    /// color comes from the active general theme; unthemed it is
    /// `tertiaryLabelColor`, which adapts to light/dark on its own.
    ///
    /// The theme is resolved for the *app's* appearance rather than a specific
    /// editor's, because this config is built once and pushed to every open
    /// document. That is the same appearance every editor has — Edmund does not
    /// mix light and dark windows.
    @MainActor static var invisiblesConfig: InvisiblesConfig? {
        guard showInvisibles else { return nil }
        // `NSApplication.shared`, not `NSApp`: the latter is an implicitly
        // unwrapped global that is still nil until the app instance is first
        // created, and this is reachable from early setup.
        let appearance = NSApplication.shared.effectiveAppearance
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let themed = ThemeStore.shared.general(dark: dark).invisibles.flatMap(NSColor.init(hex:))
        return InvisiblesConfig(
            lineEnding: invisibleLineEnding, tab: invisibleTab, space: invisibleSpace,
            otherWhitespace: invisibleWhitespace, otherControl: invisibleControl,
            // mode: invisiblesMode == .always ? .always : .uponSelection,
            color: themed ?? .tertiaryLabelColor)
    }

    /// Draw the vertical guides on nested list items — default off.
    static var showListIndentGuides: Bool {
        UserDefaults.standard.bool(forKey: Key.showListIndentGuides)
    }

    /// Show source line numbers — default off.
    /// Keep the caret's line vertically centered while typing — the editor's
    /// long-standing behavior, so it defaults on.
    static var typewriterMode: Bool {
        boolDefaultTrue(Key.typewriterMode)
    }

    /// Dim everything but the lines the selection touches — default off.
    static var focusMode: Bool {
        UserDefaults.standard.bool(forKey: Key.focusMode)
    }

    static var showLineNumbers: Bool {
        UserDefaults.standard.bool(forKey: Key.showLineNumbers)
    }

    /// Put the line numbers in a gutter at the window's leading edge rather than
    /// beside the text — default off.
    /// Grammar rides AppKit's continuous spell-checking pass, so it does
    /// nothing unless `spellCheck` is on too — which is why the checkbox is a
    /// sub-toggle rather than a peer.
    static var grammarCheck: Bool { UserDefaults.standard.bool(forKey: Key.grammarCheck) }

    /// Pushes every Edit-pane setting into an editor. Called when a document
    /// window is built and again — for every open document — whenever the pane
    /// changes something.
    @MainActor static func applyEditSettings(to editor: EditorTextView) {
        editor.listContinuationEnabled = continueLists
        editor.autoCloseBracketsEnabled = autoCloseBrackets
        editor.indentUsesTabs = indentStyle == .tabs
        editor.indentWidth = indentWidth
        editor.isContinuousSpellCheckingEnabled = spellCheck
        editor.isGrammarCheckingEnabled = grammarCheck
        editor.invisibles = invisiblesConfig
        editor.showListIndentGuides = showListIndentGuides
        editor.showLineNumbers = showLineNumbers
        editor.typewriterModeEnabled = typewriterMode
        editor.focusMode = focusMode
        editor.refreshOverdraw()
    }

    /// Applies the Edit-pane settings to every open document (editor behavior
    /// and toolbar visibility), for live changes from the Settings window and
    /// the View menu.
    @MainActor static func applyEditSettingsToOpenDocuments() {
        for case let document as Document in NSDocumentController.shared.documents {
            if let editor = document.editor { applyEditSettings(to: editor) }
            document.applyToolbarVisibility()
            document.refreshFormatBar()
        }
    }

    @MainActor static func applyAppearance() {
        switch appearanceMode {
        case .matchSystem:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Screen physical-unit helpers

extension NSScreen {
    /// Physical pixels-per-inch from the display's actual diagonal/width size
    /// (via Core Graphics — not the nominal 72 pt/in). Falls back to 109 PPI
    /// (the typical value for a 27-inch 5K iMac) when the display ID can't be read.
    var physicalPPI: CGFloat {
        guard let n = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return 109
        }
        let mm = CGDisplayScreenSize(CGDirectDisplayID(n.uint32Value))
        guard mm.width > 0 else { return 109 }
        // frame.width is in points (not pixels); mm.width is physical mm.
        return frame.width / (mm.width / 25.4)
    }

    /// Convert a physical centimetre value to AppKit points on this display.
    func cmToPoints(_ cm: Double) -> CGFloat {
        CGFloat(cm) / 2.54 * physicalPPI
    }

    /// The display's full physical width in centimetres.
    var physicalWidthCm: Double {
        Double(frame.width / physicalPPI) * 2.54
    }
}
