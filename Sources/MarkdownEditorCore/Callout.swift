import Foundation

/// Visual style for a callout type. Fields are plain and serializable (hex
/// strings, enums) so the mapping can be overridden from user settings — custom
/// color, icon, border, background. Colors are resolved to `NSColor` at render
/// time, picking the dark variant under a dark appearance when one is provided.
public struct CalloutStyle: Sendable, Equatable {

    /// Which edges of the callout draw a border.
    public struct Edges: OptionSet, Sendable, Equatable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let left   = Edges(rawValue: 1 << 0)
        public static let top    = Edges(rawValue: 1 << 1)
        public static let right  = Edges(rawValue: 1 << 2)
        public static let bottom = Edges(rawValue: 1 << 3)
        public static let all: Edges = [.left, .top, .right, .bottom]
    }

    /// SF Symbol name for the icon.
    public let symbolName: String
    /// Accent color (icon + title); border/background default to it.
    public let colorHex: String
    /// Accent under a dark appearance (defaults to `colorHex`).
    public let darkColorHex: String?

    /// Explicit border color (defaults to the accent).
    public let borderColorHex: String?
    public let darkBorderColorHex: String?
    /// Explicit background color (defaults to the accent at `backgroundAlpha`).
    public let backgroundColorHex: String?
    public let darkBackgroundColorHex: String?
    /// Alpha used for the derived background when no explicit background is set.
    public let backgroundAlpha: CGFloat

    /// Which edges draw a border, and how thick.
    public let borderEdges: Edges
    public let borderWidth: CGFloat

    public init(symbolName: String,
                colorHex: String,
                darkColorHex: String? = nil,
                borderColorHex: String? = nil,
                darkBorderColorHex: String? = nil,
                backgroundColorHex: String? = nil,
                darkBackgroundColorHex: String? = nil,
                backgroundAlpha: CGFloat = 0.08,
                borderEdges: Edges = .left,
                borderWidth: CGFloat = 3) {
        self.symbolName = symbolName
        self.colorHex = colorHex
        self.darkColorHex = darkColorHex
        self.borderColorHex = borderColorHex
        self.darkBorderColorHex = darkBorderColorHex
        self.backgroundColorHex = backgroundColorHex
        self.darkBackgroundColorHex = darkBackgroundColorHex
        self.backgroundAlpha = backgroundAlpha
        self.borderEdges = borderEdges
        self.borderWidth = borderWidth
    }

    /// The accent hex for the given appearance.
    public func accentHex(dark: Bool) -> String { (dark ? darkColorHex : nil) ?? colorHex }
    /// The border hex for the given appearance (falls back to the accent).
    public func resolvedBorderHex(dark: Bool) -> String {
        (dark ? darkBorderColorHex : nil) ?? borderColorHex ?? accentHex(dark: dark)
    }
    /// An explicit background hex for the given appearance, if any (else the
    /// renderer derives one from the accent at `backgroundAlpha`).
    public func explicitBackgroundHex(dark: Bool) -> String? {
        (dark ? darkBackgroundColorHex : nil) ?? backgroundColorHex
    }
}

/// GitHub-flavored callouts (a.k.a. admonitions): a block quote whose first line
/// is `[!type]` (case-insensitive), e.g.
///
///     > [!note]
///     > Body text.
///
/// swift-markdown has no native support for this syntax — it parses the quote as
/// a plain `BlockQuote`, and its `BlockDirective` feature is the unrelated DocC
/// `@name { … }` form — so we detect the `[!type]` marker ourselves on top of the
/// existing block-quote span.
public enum Callout {

    /// Default type → style map (lowercased keys), mirroring GitHub's five
    /// built-in callouts (with light + dark accents). Designed to be merged with
    /// user overrides.
    public static let defaultStyles: [String: CalloutStyle] = [
        "note":      CalloutStyle(symbolName: "info.circle.fill",              colorHex: "#0969DA", darkColorHex: "#1F6FEB"),
        "tip":       CalloutStyle(symbolName: "lightbulb.fill",                colorHex: "#1A7F37", darkColorHex: "#3FB950"),
        "important": CalloutStyle(symbolName: "exclamationmark.bubble.fill",   colorHex: "#8250DF", darkColorHex: "#A371F7"),
        "warning":   CalloutStyle(symbolName: "exclamationmark.triangle.fill", colorHex: "#9A6700", darkColorHex: "#D29922"),
        "caution":   CalloutStyle(symbolName: "exclamationmark.octagon.fill",  colorHex: "#CF222E", darkColorHex: "#F85149"),
    ]

    /// The style for `type` (case-insensitive), or `nil` if it isn't a known
    /// callout type — in which case the block stays a plain block quote, matching
    /// GitHub. `overrides` lets a future settings layer supply custom types/styles.
    public static func style(for type: String,
                             overrides: [String: CalloutStyle] = [:]) -> CalloutStyle? {
        let key = type.lowercased()
        return overrides[key] ?? defaultStyles[key]
    }

    /// The displayed title for a callout: the custom title if the header line has
    /// one after `[!type]`, otherwise the capitalized type name — so `[!note]`
    /// and `[!NOTE]` both render as "Note".
    public static func title(type: String, customTitle: String) -> String {
        let trimmed = customTitle.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? type.capitalized : trimmed
    }

    /// A matched `[!type]` marker, with UTF-16 ranges relative to the scanned
    /// first-line string.
    public struct Marker: Equatable {
        public let type: String          // lowercased
        public let openBracket: NSRange  // "[!"
        public let typeRange: NSRange    // the type word
        public let closeBracket: NSRange // "]"
    }

    /// Matches a callout marker `[!type]` at the start of `firstLine` (a block
    /// quote's first line, after its `> `). Returns the lowercased type and the
    /// component ranges, or `nil` if there's no marker.
    public static func parseMarker(_ firstLine: String) -> Marker? {
        let ns = firstLine as NSString
        guard let m = markerRegex.firstMatch(
            in: firstLine, options: [],
            range: NSRange(location: 0, length: ns.length)) else { return nil }
        let typeRange = m.range(at: 1)
        let type = ns.substring(with: typeRange).lowercased()
        return Marker(
            type: type,
            openBracket: NSRange(location: typeRange.location - 2, length: 2),
            typeRange: typeRange,
            closeBracket: NSRange(location: typeRange.upperBound, length: 1)
        )
    }

    /// `[!type]` at the very start of the line (optional leading spaces). The
    /// type is one or more letters/digits/`-`/`_` beginning with a letter.
    private static let markerRegex = try! NSRegularExpression(
        pattern: #"^[ \t]*\[!([A-Za-z][A-Za-z0-9_-]*)\]"#)
}
