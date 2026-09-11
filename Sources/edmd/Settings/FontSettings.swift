// FontSettings — owns the editor fonts, line height, and accent hex, bridges the
// AppKit font panel, and applies changes to every open document.

import SwiftUI
import AppKit
import EdmundCore

// MARK: - Font / theme state

/// Owns the editor's standard/monospace fonts and line height, bridges the
/// AppKit font panel, and applies font/line-height changes to open documents
/// (the genuinely AppKit-bound part of the Appearance pane).
@MainActor
final class FontSettings: NSObject, ObservableObject {
    @Published var standardFont: NSFont
    @Published var monospaceFont: NSFont
    @Published var lineHeight: CGFloat
    @Published var standardLigatures: Bool { didSet { applyLigatures() } }
    @Published var monospaceLigatures: Bool { didSet { applyLigatures() } }
    /// A single editor-wide antialias setting (both font toggles share it).
    @Published var antialias: Bool { didSet { applyAntialias() } }
    /// Per-script font overrides for the Appearance pane's "Fonts by script"
    /// section (script → family name).
    @Published var cascadeFonts: [FontCascadeScript: String]
    /// Per-script size ratios (script → multiplier of the run's size;
    /// absent = 1.0). Persisted with the theme; see EditorTheme.
    @Published var cascadeSizeRatios: [FontCascadeScript: Double]
    /// Per-script ligature switches (script → on; absent = on).
    @Published var cascadeLigatures: [FontCascadeScript: Bool]

    /// The ratio clamp — shared by the storage path (setCascadeSizeRatio) and
    /// the stepper's bounds (cascadePointSizeRange), so the control can never
    /// offer a value the model would refuse.
    static let minCascadeSizeRatio = 0.5
    static let maxCascadeSizeRatio = 2.0

    /// The font preset the Appearance pane's picker names. Edits are written
    /// into it as well as into the `Editor*` keys, so the preset the picker
    /// names always *is* what is on screen — there is no "modified" state to
    /// explain, and no way to silently diverge from it.
    ///
    /// Antialiasing is the exception, being a display setting rather than
    /// typography: it never reaches a preset.
    var editingPreset: String?

    /// Set while `apply(preset:)` is assigning the published mirrors. Each of
    /// those carries a `didSet` that commits, and committing writes the preset
    /// back — so without this, merely *choosing* a bundled preset saved a user
    /// copy of it, which then reads as an edited built-in and offers itself to
    /// Restore Defaults.
    private var isApplying = false

    private var theme: EditorTheme
    private enum Target { case standard, monospace, cascade(FontCascadeScript) }
    private var target: Target = .standard

    override init() {
        let theme = EditorTheme.load()
        self.theme = theme
        standardFont = theme.bodyFont
        monospaceFont = theme.monospaceFont()
        standardLigatures = theme.standardLigatures
        monospaceLigatures = theme.monospaceLigatures
        antialias = theme.antialias
        cascadeFonts = theme.fontCascade
        cascadeSizeRatios = theme.fontCascadeSizeRatios
        cascadeLigatures = theme.fontCascadeLigatures
        let size = theme.bodyFont.pointSize
        lineHeight = size > 0 ? max(1, min(3, (size + theme.lineSpacing) / size)) : 1
        super.init()
    }

    var standardSummary: String { Self.summary(standardFont) }
    var monospaceSummary: String { Self.summary(monospaceFont) }

    func selectStandardFont() { beginFontPanel(.standard, current: standardFont) }
    func selectMonospaceFont() { beginFontPanel(.monospace, current: monospaceFont) }
    /// The panel sets both the family and the size for cascade entries; the
    /// size is stored back as a ratio of the body size (see
    /// `setCascadePointSize`). It used to be ignored here because each row
    /// carried its own point stepper — the row's font button replaced it.
    func selectCascadeFont(_ script: FontCascadeScript) {
        beginFontPanel(.cascade(script),
                       current: previewFont(for: script) ?? NSFont.systemFont(ofSize: 16))
    }

    func setStandardSize(_ size: CGFloat) {
        standardFont = NSFont(descriptor: standardFont.fontDescriptor, size: size) ?? standardFont
        applyTheme()
    }

    func setMonospaceSize(_ size: CGFloat) {
        monospaceFont = NSFont(descriptor: monospaceFont.fontDescriptor, size: size) ?? monospaceFont
        applyMonospace()
    }

    func setLineHeight(_ value: CGFloat) {
        lineHeight = max(1, min(3, value))
        applyTheme()
    }

    @objc func changeFont(_ sender: NSFontManager) {
        switch target {
        case .standard:
            standardFont = sender.convert(standardFont)
            applyTheme()
        case .monospace:
            monospaceFont = sender.convert(monospaceFont)
            applyMonospace()
        case .cascade(let script):
            // The panel converts a specific face; the cascade persists the
            // FAMILY — the resolver picks bold/italic members itself (and
            // stroke-synthesizes when the family has none).
            let converted = sender.convert(previewFont(for: script)
                                           ?? NSFont.systemFont(ofSize: 16))
            setCascadeFont(script, family: converted.familyName ?? converted.fontName)
            // The panel is now the row's only size control, so its size has to
            // land somewhere: store it as this script's ratio of the body size.
            setCascadePointSize(script, points: Double(converted.pointSize))
        }
    }

    private func beginFontPanel(_ target: Target, current: NSFont) {
        self.target = target
        let manager = NSFontManager.shared
        manager.target = self
        manager.action = #selector(changeFont(_:))
        manager.setSelectedFont(current, isMultiple: false)
        manager.orderFrontFontPanel(nil)
    }

    private func applyMonospace() {
        var updated = theme
        updated.monospaceFontName = monospaceFont.fontName
        updated.monospaceFontSize = monospaceFont.pointSize
        theme = updated
        commit(updated)
    }

    private func applyLigatures() {
        var updated = theme
        updated.standardLigatures = standardLigatures
        updated.monospaceLigatures = monospaceLigatures
        theme = updated
        commit(updated)
    }

    private func applyAntialias() {
        var updated = theme
        updated.antialias = antialias
        theme = updated
        // Not `commit`: antialiasing is a display setting, not typography, and
        // a preset never carries it.
        updated.save()
        applyToDocuments(updated)
    }

    private func applyTheme() {
        var updated = theme
        updated.fontName = standardFont.fontName
        updated.fontSize = standardFont.pointSize
        updated.lineSpacing = max(0, (lineHeight - 1) * standardFont.pointSize)
        theme = updated
        commit(updated)
    }

    /// Where an edit goes: into the preset the picker names, and into the live
    /// settings and every open document. The selected preset *is* the one in
    /// force, so there is only ever one destination.
    private func commit(_ updated: EditorTheme) {
        syncPreset()
        updated.save()
        applyToDocuments(updated)
    }

    /// Mirrors the live values into the preset the picker names, if any.
    private func syncPreset() {
        guard !isApplying, let name = editingPreset,
              let existing = ThemeStore.shared.fontThemes().first(where: { $0.name == name })
        else { return }
        try? ThemeStore.shared.save(
            theme.fontTheme(name: name, displayName: existing.displayName))
    }

    /// Puts a preset in force: its values become the `Editor*` keys and every
    /// open document is repainted. Choosing one in the picker is choosing it.
    func apply(preset: FontTheme) {
        isApplying = true
        defer { isApplying = false }
        editingPreset = preset.name
        let updated = theme.applying(preset)
        theme = updated
        standardFont = updated.bodyFont
        monospaceFont = updated.monospaceFont()
        standardLigatures = updated.standardLigatures
        monospaceLigatures = updated.monospaceLigatures
        cascadeFonts = updated.fontCascade
        cascadeSizeRatios = updated.fontCascadeSizeRatios
        cascadeLigatures = updated.fontCascadeLigatures
        let size = updated.bodyFont.pointSize
        lineHeight = size > 0 ? max(1, min(3, (size + updated.lineSpacing) / size)) : 1
        updated.save()
        // Deliberately no `syncPreset()`: this is applying a preset, not
        // editing one. Writing it back would save a user copy of a bundled
        // preset merely because it had been *chosen*.
        applyToDocuments(updated)
    }

    /// Whether the typography still holds what Edmund ships with.
    var isDefault: Bool { theme == .default }

    private func applyToDocuments(_ theme: EditorTheme) {
        for case let document as Document in NSDocumentController.shared.documents {
            document.editor?.applyTheme(theme)
            // Reflect the theme change live in an open Read view too.
            document.refreshReadView()
        }
    }

    // MARK: - Font cascade (per-script fonts, Fonts pane)

    /// Every installed font family, for the per-script pickers. The codebase's
    /// only system-font enumeration; sorted for a stable menu order.
    ///
    /// Cached once per FontSettings (created once per Settings window): the
    /// menu re-enumerates it on every render, and instantiating an NSFont per
    /// family per row on a stock Mac is thousands of allocations per pane
    /// render — a visible hitch in the settings window.
    let availableFontFamilies: [String] = NSFontManager.shared.availableFontFamilies.sorted()

    /// Family → display name, computed on first use. Some families report a
    /// friendlier display name via an instantiated font than their raw name;
    /// that instantiation is once per family, not once per row per render.
    private var familyDisplayNames: [String: String] = [:]

    /// The display name for a family, cached after the first lookup.
    func displayName(for family: String) -> String {
        if let cached = familyDisplayNames[family] { return cached }
        let name = NSFont(name: family, size: 12)?.displayName ?? family
        familyDisplayNames[family] = name
        return name
    }

    /// Sets (or clears, with nil/empty) the user's font for one script and
    /// broadcasts the change live to every open document and Read view.
    /// Clearing also drops the script's size ratio: an orphan ratio would
    /// silently re-apply if the font is ever set again.
    func setCascadeFont(_ script: FontCascadeScript, family: String?) {
        var updated = theme
        if let family, !family.isEmpty {
            updated.fontCascade[script] = family
        } else {
            updated.fontCascade.removeValue(forKey: script)
            updated.fontCascadeSizeRatios.removeValue(forKey: script)
            updated.fontCascadeLigatures.removeValue(forKey: script)
        }
        cascadeFonts = updated.fontCascade
        cascadeSizeRatios = updated.fontCascadeSizeRatios
        cascadeLigatures = updated.fontCascadeLigatures
        theme = updated
        commit(updated)
    }

    /// Sets (or clears, at 1.0) a script's size ratio and broadcasts live.
    func setCascadeSizeRatio(_ script: FontCascadeScript, ratio: Double) {
        var updated = theme
        let clamped = min(Self.maxCascadeSizeRatio, max(Self.minCascadeSizeRatio, ratio))
        if abs(clamped - 1.0) < 0.001 {
            updated.fontCascadeSizeRatios.removeValue(forKey: script)
        } else {
            updated.fontCascadeSizeRatios[script] = clamped
        }
        cascadeSizeRatios = updated.fontCascadeSizeRatios
        theme = updated
        commit(updated)
    }

    /// A script's size ratio; 1.0 when unset.
    func cascadeSizeRatio(for script: FontCascadeScript) -> Double {
        cascadeSizeRatios[script] ?? 1.0
    }

    /// A script's ligature switch; on when unset (only "off" is stored).
    func cascadeLigatures(for script: FontCascadeScript) -> Bool {
        cascadeLigatures[script] ?? true
    }

    /// Sets a script's ligature switch and broadcasts live.
    func setCascadeLigatures(_ script: FontCascadeScript, on: Bool) {
        var updated = theme
        if on {
            updated.fontCascadeLigatures.removeValue(forKey: script)
        } else {
            updated.fontCascadeLigatures[script] = false
        }
        cascadeLigatures = updated.fontCascadeLigatures
        theme = updated
        commit(updated)
    }

    /// A script's displayed point size: the stored ratio rendered against the
    /// body size. The model stays a RATIO — Read mode's only per-script size
    /// lever is the relative `size-adjust` (a `@font-face` has no `font-size`
    /// descriptor), and persisting points would leave Edit and Read
    /// disagreeing the moment the body size differed — so the settings UI
    /// converts at the boundary and stores back `points / bodySize`.
    func cascadePointSize(for script: FontCascadeScript) -> Double {
        (standardFont.pointSize * cascadeSizeRatio(for: script)).rounded()
    }

    /// Stores a displayed point size back as a ratio of the body size.
    func setCascadePointSize(_ script: FontCascadeScript, points: Double) {
        guard standardFont.pointSize > 0 else { return }
        setCascadeSizeRatio(script, ratio: points / standardFont.pointSize)
    }

    /// The stepper's bounds in points: the ratio clamp rendered against the
    /// body size. Derived (not a fixed 8…72) so the control never offers a
    /// value `setCascadeSizeRatio` would clamp away — past the bounds the
    /// arrow would look live while the number stays frozen.
    var cascadePointSizeRange: ClosedRange<Double> {
        (standardFont.pointSize * Self.minCascadeSizeRatio).rounded()
            ... (standardFont.pointSize * Self.maxCascadeSizeRatio).rounded()
    }

    /// The script row's font name and size ("Songti SC  17"), mirroring the
    /// Standard/Monospaced rows.
    ///
    /// Named even when the script is unset: the name is then the system
    /// fallback the editor will really render it in, which is worth saying. The
    /// row greys it, so naming it never reads as "configured" — and the sample
    /// beside it is drawn in that same face either way.
    func cascadeSummary(for script: FontCascadeScript) -> String {
        guard let font = previewFont(for: script) else { return "" }
        return Self.summary(font)
    }

    /// The preview font for a script row: the user's choice drawn at the
    /// displayed point size (body size × the script's ratio), so the number in
    /// the field is the size the text is drawn at — the same convention as the
    /// rows above.
    ///
    /// When the script is unset the row previews the face the editor will
    /// ACTUALLY use for it — the body font's CoreText fallback for that
    /// script's sample, the same `CTFontCreateForString` call the storage's
    /// substitution pass makes. Falling through to the default UI font instead
    /// drew every unset row in the UI font, which is not what any of that text
    /// renders as in the editor.
    func previewFont(for script: FontCascadeScript) -> NSFont? {
        let size = standardFont.pointSize * cascadeSizeRatio(for: script)
        if let family = cascadeFonts[script] {
            return NSFont(name: family, size: size)
        }
        let base = NSFont(descriptor: standardFont.fontDescriptor, size: size) ?? standardFont
        let sample = script.sample
        return CTFontCreateForString(base as CTFont, sample as CFString,
                                     CFRange(location: 0, length: (sample as NSString).length)) as NSFont
    }

    private static func summary(_ font: NSFont) -> String {
        let name = font.displayName ?? font.familyName ?? font.fontName
        return "\(name)  \(Int(round(font.pointSize)))"
    }
}
