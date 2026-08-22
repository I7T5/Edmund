import AppKit

/// All user-configurable visual settings for the editor.
///
/// Stored as simple types (String, CGFloat) so it serializes cleanly to
/// UserDefaults. Computed properties provide the `NSFont` / `NSColor`
/// equivalents for rendering.
public struct EditorTheme: Equatable, Sendable {

    // MARK: - Font

    public var fontName: String
    public var fontSize: CGFloat

    /// Monospaced font for code (inline, blocks, tables). An empty name means the
    /// system monospaced font.
    public var monospaceFontName: String
    public var monospaceFontSize: CGFloat

    /// Whether ligatures are enabled for the standard (body) and monospaced fonts.
    public var standardLigatures: Bool
    public var monospaceLigatures: Bool

    /// Whether editor text is antialiased (a single editor-wide setting).
    public var antialias: Bool

    /// Per-script font overrides: script → macOS font family name. Empty means
    /// no cascade — the editor and Read mode behave exactly as before (system
    /// fallback picks covering fonts).
    public var fontCascade: [FontCascadeScript: String]

    /// Per-script size overrides: script → multiplier of the run's point size
    /// (absent = 1.0). Ratios, not points, so zoom and body-size changes scale
    /// the cascade for free; Read mode carries the same ratio via the
    /// @font-face `size-adjust` descriptor, keeping Edit and Read in step.
    public var fontCascadeSizeRatios: [FontCascadeScript: Double]

    // MARK: - Colors (hex strings, e.g. "#3366E6")

    public var linkBlueHex: String
    public var codeHex: String
    /// Color for LaTeX operators/commands (`_`, `^`, `\sum`, …) in raw math.
    public var mathOperatorHex: String
    /// Color for numbers in raw math.
    public var mathNumberHex: String

    // MARK: - Spacing

    public var lineSpacing: CGFloat
    public var paragraphSpacingBefore: CGFloat

    public init(fontName: String, fontSize: CGFloat, linkBlueHex: String, codeHex: String,
                lineSpacing: CGFloat, paragraphSpacingBefore: CGFloat,
                mathOperatorHex: String = "#D70015", mathNumberHex: String = "#C77800",
                monospaceFontName: String = "", monospaceFontSize: CGFloat = 14,
                standardLigatures: Bool = true, monospaceLigatures: Bool = false,
                antialias: Bool = true, fontCascade: [FontCascadeScript: String] = [:],
                fontCascadeSizeRatios: [FontCascadeScript: Double] = [:]) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.linkBlueHex = linkBlueHex
        self.codeHex = codeHex
        self.lineSpacing = lineSpacing
        self.paragraphSpacingBefore = paragraphSpacingBefore
        self.mathOperatorHex = mathOperatorHex
        self.mathNumberHex = mathNumberHex
        self.monospaceFontName = monospaceFontName
        self.monospaceFontSize = monospaceFontSize
        self.standardLigatures = standardLigatures
        self.monospaceLigatures = monospaceLigatures
        self.antialias = antialias
        self.fontCascade = fontCascade
        self.fontCascadeSizeRatios = fontCascadeSizeRatios
    }

    // MARK: - Defaults

    public static let `default` = EditorTheme(
        fontName: "Iowan Old Style",
        fontSize: 16,
        linkBlueHex: "#3366E6",
        codeHex: "#8A2425",
        lineSpacing: 4,
        paragraphSpacingBefore: 2
    )

    /// Theme for the Quick Look preview: `.default` but in the system UI font
    /// (`system-ui`, resolved by `HTMLTheme.cssFontStack`) rather than the
    /// editor's serif body face.
    public static let quickLook: EditorTheme = {
        var t = EditorTheme.default
        t.fontName = "system-ui"
        return t
    }()

    // MARK: - Derived Properties

    @MainActor public var bodyFont: NSFont {
        let base = NSFont(name: fontName, size: fontSize) ?? .systemFont(ofSize: fontSize)
        return Self.applyingLigatures(standardLigatures, to: base)
    }

    /// The monospaced font, at `size` (default: the theme's monospace size).
    /// Falls back to the system monospaced font when no family is set or it can't
    /// be loaded.
    @MainActor public func monospaceFont(ofSize size: CGFloat? = nil) -> NSFont {
        let resolved = size ?? monospaceFontSize
        let base: NSFont = {
            if !monospaceFontName.isEmpty, let font = NSFont(name: monospaceFontName, size: resolved) {
                return font
            }
            // Default when no family is chosen: Input Mono Narrow, then Input Mono,
            // then the system monospaced font — all Regular.
            for name in ["InputMonoNarrow-Regular", "InputMono-Regular"] {
                if let font = NSFont(name: name, size: resolved) { return font }
            }
            return .monospacedSystemFont(ofSize: resolved, weight: .regular)
        }()
        return Self.applyingLigatures(monospaceLigatures, to: base)
    }

    /// Returns `font` with ligatures disabled (when `on` is false) by turning off
    /// both common ligatures and contextual alternates in its descriptor — the
    /// latter is what drives programming ligatures like Fira Code's `=>`/`==`.
    /// Baking it into the font (rather than the `.ligature` attribute) is what the
    /// editor's TextKit 2 pipeline reliably honors.
    private static func applyingLigatures(_ on: Bool, to font: NSFont) -> NSFont {
        guard !on else { return font }
        let kContextualAlternatesType = 36
        let kContextualAlternatesOffSelector = 1
        let settings: [[NSFontDescriptor.FeatureKey: Int]] = [
            [.typeIdentifier: kLigaturesType, .selectorIdentifier: kCommonLigaturesOffSelector],
            [.typeIdentifier: kContextualAlternatesType, .selectorIdentifier: kContextualAlternatesOffSelector],
        ]
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: settings])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    /// Body-text ink — **the** definition, read by both Edit mode
    /// (`EditorTextView.foregroundColor`) and Read mode (`HTMLTheme`'s `--fg`,
    /// and the math bitmaps `DocumentHTML` embeds). It lives here because the two
    /// modes had drifted: Edit mode painted the system `textColor` while Read
    /// mode hard-coded `#1a1a1a`, so in light mode the identical equation was
    /// pure black in one mode and 10% lighter in the other (measured off
    /// screenshots: peak ink coverage 1.000 vs 0.863).
    ///
    /// Light mode keeps the system color: Edit mode is a real `NSTextView`, and
    /// `textColor` is what every native text surface paints — it also tracks
    /// Increase Contrast, which a hex cannot. On white the difference from
    /// `#1a1a1a` is perceptually tiny (21:1 vs 18.9:1 contrast), so matching the
    /// system costs nothing. Dark mode is the exception, and it predates this:
    /// `textColor` is pure white there, which glares against the `#292929` page,
    /// so both modes use Read mode's long-standing `#e6e6e6` instead.
    @MainActor public static func bodyTextColor(dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 230 / 255, green: 230 / 255, blue: 230 / 255, alpha: 1)
             : .textColor
    }

    /// `bodyTextColor(dark:)` resolved against that appearance rather than
    /// whichever one happens to be current. Read mode needs this: its CSS and its
    /// math bitmaps are generated for an explicit light/dark target (an export, or
    /// a preview while the app sits in the other appearance), and a dynamic
    /// `textColor` resolved at the wrong moment would bake in the wrong ink.
    @MainActor public static func bodyTextColorResolved(dark: Bool) -> NSColor {
        var color = bodyTextColor(dark: dark)
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            color = color.usingColorSpace(.deviceRGB) ?? color
        }
        return color
    }

    @MainActor public var linkBlueColor: NSColor {
        NSColor(hex: linkBlueHex) ?? .systemBlue
    }

    @MainActor public var codeColor: NSColor {
        NSColor(hex: codeHex) ?? .systemRed
    }

    @MainActor public var mathOperatorColor: NSColor {
        NSColor(hex: mathOperatorHex) ?? .systemRed
    }

    @MainActor public var mathNumberColor: NSColor {
        NSColor(hex: mathNumberHex) ?? .systemOrange
    }

    // MARK: - UserDefaults Persistence

    private enum Keys {
        static let fontName = "EditorFontName"
        static let fontSize = "EditorFontSize"
        static let monospaceFontName = "EditorMonospaceFontName"
        static let monospaceFontSize = "EditorMonospaceFontSize"
        static let standardLigatures = "EditorStandardLigatures"
        static let monospaceLigatures = "EditorMonospaceLigatures"
        static let antialias = "EditorAntialias"
        static let linkBlueHex = "EditorLinkBlueHex"
        static let codeHex = "EditorCodeHex"
        static let mathOperatorHex = "EditorMathOperatorHex"
        static let mathNumberHex = "EditorMathNumberHex"
        static let lineSpacing = "EditorLineSpacing"
        static let paragraphSpacingBefore = "EditorParagraphSpacingBefore"
        static let fontCascade = "EditorFontCascade"
        static let fontCascadeSizeRatios = "EditorFontCascadeSizeRatios"
    }

    public static func load(from defaults: UserDefaults = .standard) -> EditorTheme {
        let d = defaults
        let def = EditorTheme.default

        let fontName = d.string(forKey: Keys.fontName) ?? def.fontName
        let fontSize: CGFloat = {
            let v = CGFloat(d.float(forKey: Keys.fontSize))
            return v > 0 ? v : def.fontSize
        }()
        // The accent color is not user-customizable; always use the default so a
        // stale persisted value (e.g. left over from the removed in-app accent
        // picker) can't leak in and recolor links.
        let linkBlueHex = def.linkBlueHex
        let monospaceFontName = d.string(forKey: Keys.monospaceFontName) ?? def.monospaceFontName
        let monospaceFontSize: CGFloat = {
            let v = CGFloat(d.float(forKey: Keys.monospaceFontSize))
            return v > 0 ? v : def.monospaceFontSize
        }()
        let standardLigatures = d.object(forKey: Keys.standardLigatures) as? Bool ?? def.standardLigatures
        let monospaceLigatures = d.object(forKey: Keys.monospaceLigatures) as? Bool ?? def.monospaceLigatures
        let antialias = d.object(forKey: Keys.antialias) as? Bool ?? def.antialias
        let codeHex = d.string(forKey: Keys.codeHex) ?? def.codeHex
        let mathOperatorHex = d.string(forKey: Keys.mathOperatorHex) ?? def.mathOperatorHex
        let mathNumberHex = d.string(forKey: Keys.mathNumberHex) ?? def.mathNumberHex
        let lineSpacing: CGFloat = d.object(forKey: Keys.lineSpacing) != nil
            ? CGFloat(d.float(forKey: Keys.lineSpacing))
            : def.lineSpacing
        let paragraphSpacingBefore: CGFloat = d.object(forKey: Keys.paragraphSpacingBefore) != nil
            ? CGFloat(d.float(forKey: Keys.paragraphSpacingBefore))
            : def.paragraphSpacingBefore
        // Unknown script keys are dropped so a cascade written by a newer (or
        // older) build with a different curated list still loads cleanly.
        let fontCascade: [FontCascadeScript: String] = {
            guard let raw = d.dictionary(forKey: Keys.fontCascade) as? [String: String] else {
                return [:]
            }
            var cascade: [FontCascadeScript: String] = [:]
            for (key, family) in raw {
                if let script = FontCascadeScript(rawValue: key), !family.isEmpty {
                    cascade[script] = family
                }
            }
            return cascade
        }()
        // Same discipline as the families: unknown scripts dropped, ratios
        // clamped to the stepper's range, and 1.0 treated as unset (the
        // settings UI removes the entry instead of storing it).
        let fontCascadeSizeRatios: [FontCascadeScript: Double] = {
            guard let raw = d.dictionary(forKey: Keys.fontCascadeSizeRatios) else {
                return [:]
            }
            var ratios: [FontCascadeScript: Double] = [:]
            for (key, value) in raw {
                guard let script = FontCascadeScript(rawValue: key),
                      let number = value as? NSNumber else { continue }
                let ratio = min(2.0, max(0.5, number.doubleValue))
                if abs(ratio - 1.0) >= 0.001 { ratios[script] = ratio }
            }
            return ratios
        }()

        return EditorTheme(
            fontName: fontName,
            fontSize: fontSize,
            linkBlueHex: linkBlueHex,
            codeHex: codeHex,
            lineSpacing: lineSpacing,
            paragraphSpacingBefore: paragraphSpacingBefore,
            mathOperatorHex: mathOperatorHex,
            mathNumberHex: mathNumberHex,
            monospaceFontName: monospaceFontName,
            monospaceFontSize: monospaceFontSize,
            standardLigatures: standardLigatures,
            monospaceLigatures: monospaceLigatures,
            antialias: antialias,
            fontCascade: fontCascade,
            fontCascadeSizeRatios: fontCascadeSizeRatios
        )
    }

    public func save(to defaults: UserDefaults = .standard) {
        let d = defaults
        d.set(fontName, forKey: Keys.fontName)
        d.set(Float(fontSize), forKey: Keys.fontSize)
        d.set(monospaceFontName, forKey: Keys.monospaceFontName)
        d.set(Float(monospaceFontSize), forKey: Keys.monospaceFontSize)
        d.set(standardLigatures, forKey: Keys.standardLigatures)
        d.set(monospaceLigatures, forKey: Keys.monospaceLigatures)
        d.set(antialias, forKey: Keys.antialias)
        d.set(linkBlueHex, forKey: Keys.linkBlueHex)
        d.set(codeHex, forKey: Keys.codeHex)
        d.set(mathOperatorHex, forKey: Keys.mathOperatorHex)
        d.set(mathNumberHex, forKey: Keys.mathNumberHex)
        d.set(Float(lineSpacing), forKey: Keys.lineSpacing)
        d.set(Float(paragraphSpacingBefore), forKey: Keys.paragraphSpacingBefore)
        d.set(Dictionary(uniqueKeysWithValues: fontCascade.map { ($0.key.rawValue, $0.value) }),
              forKey: Keys.fontCascade)
        d.set(Dictionary(uniqueKeysWithValues: fontCascadeSizeRatios.map { ($0.key.rawValue, $0.value) }),
              forKey: Keys.fontCascadeSizeRatios)
    }
}

// MARK: - NSColor Hex Helpers

extension NSColor {

    /// Create a color from a hex string like "#3366E6" or "3366E6".
    ///
    /// sRGB, not the calibrated space: a hex literal means the same thing in CSS
    /// (Read mode, PDF export) as it does here, and calibrated RGB composites
    /// visibly lighter than that — every project hex drifted, most obviously the
    /// `warning` callout's orange (#EC7500 painted as #F28900 in the editor while
    /// Read mode showed the literal). Decoding as sRGB makes the two agree and
    /// makes hex → NSColor → `hexString` round-trip exactly.
    public convenience init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let rgb = UInt64(h, radix: 16) else { return nil }
        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >> 8) & 0xFF) / 255.0
        let b = CGFloat(rgb & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }

    /// Returns the hex string representation (e.g. "#3366E6").
    public var hexString: String {
        guard let rgb = usingColorSpace(.deviceRGB) else { return "#000000" }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
