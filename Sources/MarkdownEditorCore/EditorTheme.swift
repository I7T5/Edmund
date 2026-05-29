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

    // MARK: - Colors (hex strings, e.g. "#3366E6")

    public var accentHex: String
    public var codeHex: String

    // MARK: - Spacing

    public var lineSpacing: CGFloat
    public var paragraphSpacingBefore: CGFloat

    public init(fontName: String, fontSize: CGFloat, accentHex: String, codeHex: String,
                lineSpacing: CGFloat, paragraphSpacingBefore: CGFloat) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.accentHex = accentHex
        self.codeHex = codeHex
        self.lineSpacing = lineSpacing
        self.paragraphSpacingBefore = paragraphSpacingBefore
    }

    // MARK: - Defaults

    public static let `default` = EditorTheme(
        fontName: "Hoefler Text",
        fontSize: 16,
        accentHex: "#3366E6",
        codeHex: "#8A2425",
        lineSpacing: 4,
        paragraphSpacingBefore: 2
    )

    // MARK: - Derived Properties

    @MainActor public var bodyFont: NSFont {
        NSFont(name: fontName, size: fontSize) ?? .systemFont(ofSize: fontSize)
    }

    @MainActor public var accentColor: NSColor {
        NSColor(hex: accentHex) ?? .systemBlue
    }

    @MainActor public var codeColor: NSColor {
        NSColor(hex: codeHex) ?? .systemRed
    }

    // MARK: - UserDefaults Persistence

    private enum Keys {
        static let fontName = "EditorFontName"
        static let fontSize = "EditorFontSize"
        static let accentHex = "EditorAccentHex"
        static let codeHex = "EditorCodeHex"
        static let lineSpacing = "EditorLineSpacing"
        static let paragraphSpacingBefore = "EditorParagraphSpacingBefore"
    }

    public static func load() -> EditorTheme {
        let d = UserDefaults.standard
        let def = EditorTheme.default

        let fontName = d.string(forKey: Keys.fontName) ?? def.fontName
        let fontSize: CGFloat = {
            let v = CGFloat(d.float(forKey: Keys.fontSize))
            return v > 0 ? v : def.fontSize
        }()
        let accentHex = d.string(forKey: Keys.accentHex) ?? def.accentHex
        let codeHex = d.string(forKey: Keys.codeHex) ?? def.codeHex
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
            paragraphSpacingBefore: paragraphSpacingBefore
        )
    }

    public func save() {
        let d = UserDefaults.standard
        d.set(fontName, forKey: Keys.fontName)
        d.set(Float(fontSize), forKey: Keys.fontSize)
        d.set(accentHex, forKey: Keys.accentHex)
        d.set(codeHex, forKey: Keys.codeHex)
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
