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

    // MARK: - Colors (hex strings, e.g. "#3366E6")

    public var accentHex: String
    public var codeHex: String
    /// Color for LaTeX operators/commands (`_`, `^`, `\sum`, …) in raw math.
    public var mathOperatorHex: String
    /// Color for numbers in raw math.
    public var mathNumberHex: String

    // MARK: - Spacing

    public var lineSpacing: CGFloat
    public var paragraphSpacingBefore: CGFloat

    public init(fontName: String, fontSize: CGFloat, accentHex: String, codeHex: String,
                lineSpacing: CGFloat, paragraphSpacingBefore: CGFloat,
                mathOperatorHex: String = "#D70015", mathNumberHex: String = "#C77800",
                monospaceFontName: String = "", monospaceFontSize: CGFloat = 14,
                standardLigatures: Bool = true, monospaceLigatures: Bool = false,
                antialias: Bool = true) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.accentHex = accentHex
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
    }

    // MARK: - Defaults

    public static let `default` = EditorTheme(
        fontName: "Iowan Old Style",
        fontSize: 16,
        accentHex: "#3366E6",
        codeHex: "#8A2425",
        lineSpacing: 4,
        paragraphSpacingBefore: 2
    )

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

    @MainActor public var accentColor: NSColor {
        NSColor(hex: accentHex) ?? .systemBlue
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
        static let accentHex = "EditorAccentHex"
        static let codeHex = "EditorCodeHex"
        static let mathOperatorHex = "EditorMathOperatorHex"
        static let mathNumberHex = "EditorMathNumberHex"
        static let lineSpacing = "EditorLineSpacing"
        static let paragraphSpacingBefore = "EditorParagraphSpacingBefore"
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
        let accentHex = def.accentHex
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

        return EditorTheme(
            fontName: fontName,
            fontSize: fontSize,
            accentHex: accentHex,
            codeHex: codeHex,
            lineSpacing: lineSpacing,
            paragraphSpacingBefore: paragraphSpacingBefore,
            mathOperatorHex: mathOperatorHex,
            mathNumberHex: mathNumberHex,
            monospaceFontName: monospaceFontName,
            monospaceFontSize: monospaceFontSize,
            standardLigatures: standardLigatures,
            monospaceLigatures: monospaceLigatures,
            antialias: antialias
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
        d.set(accentHex, forKey: Keys.accentHex)
        d.set(codeHex, forKey: Keys.codeHex)
        d.set(mathOperatorHex, forKey: Keys.mathOperatorHex)
        d.set(mathNumberHex, forKey: Keys.mathNumberHex)
        d.set(Float(lineSpacing), forKey: Keys.lineSpacing)
        d.set(Float(paragraphSpacingBefore), forKey: Keys.paragraphSpacingBefore)
    }
}

// MARK: - NSColor Hex Helpers

extension NSColor {

    /// Create a color from a hex string like "#3366E6" or "3366E6".
    public convenience init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let rgb = UInt64(h, radix: 16) else { return nil }
        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >> 8) & 0xFF) / 255.0
        let b = CGFloat(rgb & 0xFF) / 255.0
        self.init(calibratedRed: r, green: g, blue: b, alpha: 1.0)
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
