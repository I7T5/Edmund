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
        let size = theme.bodyFont.pointSize
        lineHeight = size > 0 ? max(1, min(3, (size + theme.lineSpacing) / size)) : 1
        super.init()
    }

    var standardSummary: String { Self.summary(standardFont) }
    var monospaceSummary: String { Self.summary(monospaceFont) }

    func selectStandardFont() { beginFontPanel(.standard, current: standardFont) }
    func selectMonospaceFont() { beginFontPanel(.monospace, current: monospaceFont) }
    /// The panel's size is deliberately ignored for cascade entries — a
    /// script's size is its ratio stepper, not an absolute point size.
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
        updated.save()
        applyToDocuments(updated)
    }

    private func applyLigatures() {
        var updated = theme
        updated.standardLigatures = standardLigatures
        updated.monospaceLigatures = monospaceLigatures
        theme = updated
        updated.save()
        applyToDocuments(updated)
    }

    private func applyAntialias() {
        var updated = theme
        updated.antialias = antialias
        theme = updated
        updated.save()
        applyToDocuments(updated)
    }

    private func applyTheme() {
        var updated = theme
        updated.fontName = standardFont.fontName
        updated.fontSize = standardFont.pointSize
        updated.lineSpacing = max(0, (lineHeight - 1) * standardFont.pointSize)
        theme = updated
        updated.save()
        applyToDocuments(updated)
    }

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
    func setCascadeFont(_ script: FontCascadeScript, family: String?) {
        var updated = theme
        if let family, !family.isEmpty {
            updated.fontCascade[script] = family
        } else {
            updated.fontCascade.removeValue(forKey: script)
        }
        cascadeFonts = updated.fontCascade
        theme = updated
        updated.save()
        applyToDocuments(updated)
    }

    /// Sets (or clears, at 1.0) a script's size ratio and broadcasts live.
    func setCascadeSizeRatio(_ script: FontCascadeScript, ratio: Double) {
        var updated = theme
        let clamped = min(2.0, max(0.5, ratio))
        if abs(clamped - 1.0) < 0.001 {
            updated.fontCascadeSizeRatios.removeValue(forKey: script)
        } else {
            updated.fontCascadeSizeRatios[script] = clamped
        }
        cascadeSizeRatios = updated.fontCascadeSizeRatios
        theme = updated
        updated.save()
        applyToDocuments(updated)
    }

    /// A script's size ratio; 1.0 when unset.
    func cascadeSizeRatio(for script: FontCascadeScript) -> Double {
        cascadeSizeRatios[script] ?? 1.0
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

    /// The script row's field text, mirroring the Standard/Monospaced rows:
    /// family and absolute point size ("Songti SC  17") when the script has a
    /// font, else the script's sample glyph — a system-fallback family cannot
    /// be named, so the sample stands in for it.
    func cascadeSummary(for script: FontCascadeScript) -> String {
        guard let font = previewFont(for: script) else { return script.sample }
        return Self.summary(font)
    }

    /// The preview font for a script row: the user's choice drawn at the
    /// displayed point size (body size × the script's ratio), so the number in
    /// the field is the size the text is drawn at — the same convention as the
    /// rows above. Nil when unset (the row then draws in the default UI font,
    /// which itself falls back per-script — a reasonable "system fallback"
    /// preview).
    func previewFont(for script: FontCascadeScript) -> NSFont? {
        guard let family = cascadeFonts[script] else { return nil }
        return NSFont(name: family, size: standardFont.pointSize * cascadeSizeRatio(for: script))
    }

    private static func summary(_ font: NSFont) -> String {
        let name = font.displayName ?? font.familyName ?? font.fontName
        return "\(name)  \(Int(round(font.pointSize)))"
    }
}
