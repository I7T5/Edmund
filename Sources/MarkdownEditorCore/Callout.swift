import Foundation

/// Visual style for a callout type. Fields are plain and serializable so the
/// mapping can later be overridden from user settings (custom color / icon).
/// `symbolName` is an SF Symbol; `colorHex` is an "#RRGGBB" string resolved to
/// an `NSColor` at render time.
public struct CalloutStyle: Sendable, Equatable {
    public let symbolName: String
    public let colorHex: String

    public init(symbolName: String, colorHex: String) {
        self.symbolName = symbolName
        self.colorHex = colorHex
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
    /// built-in callouts. Designed to be merged with user overrides later.
    public static let defaultStyles: [String: CalloutStyle] = [
        "note":      CalloutStyle(symbolName: "info.circle.fill",              colorHex: "#0969DA"),
        "tip":       CalloutStyle(symbolName: "lightbulb.fill",                colorHex: "#1A7F37"),
        "important": CalloutStyle(symbolName: "exclamationmark.bubble.fill",   colorHex: "#8250DF"),
        "warning":   CalloutStyle(symbolName: "exclamationmark.triangle.fill", colorHex: "#9A6700"),
        "caution":   CalloutStyle(symbolName: "exclamationmark.octagon.fill",  colorHex: "#CF222E"),
    ]

    /// The style for `type` (case-insensitive), or `nil` if it isn't a known
    /// callout type — in which case the block stays a plain block quote, matching
    /// GitHub. `overrides` lets a future settings layer supply custom types/styles.
    public static func style(for type: String,
                             overrides: [String: CalloutStyle] = [:]) -> CalloutStyle? {
        let key = type.lowercased()
        return overrides[key] ?? defaultStyles[key]
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
