import Foundation

// MARK: - Themes
//
// Two JSON-backed theme kinds, both loaded by `ThemeStore`:
//
//   - `GeneralTheme` colors the editor chrome (ink, page, selection, caret,
//     invisibles, checkbox, links).
//   - `SyntaxTheme` colors fenced code blocks — one hex per
//     `CodeHighlighter.TokenType`, plus `plain` for un-tokenized text.
//
// Both declare the appearance they are legible on, and the app keeps one active
// theme per appearance per kind, swapping on light ↔ dark.
//
// A `nil` color means "use the platform default for this role" — the "Use
// system color" checkbox in Settings ▸ Themes. It is not the same as absent
// data: `Default (Light)` genuinely wants `NSColor.textColor` for its ink
// rather than a hex, because the semantic color tracks Increase Contrast and a
// hex cannot (see `EditorTheme.bodyTextColor`). Resolution of `nil` lives at
// the call site, next to the value it falls back to.

/// The appearance a theme is designed for. Shown as a `(Light)`/`(Dark)` suffix
/// on the theme's display name.
public enum ThemeAppearance: String, Codable, Sendable {
    case light, dark
}

// MARK: - General Theme

/// The editor chrome colors, plus the code-syntax theme this one hands off to.
///
/// `syntaxTheme` names a theme rather than restating its values, so adding a
/// token color to that kind never widens this struct. A theme that leaves it
/// `nil` falls back to whichever syntax theme is active for its appearance —
/// the pane shows that resolved name, so the popup is never blank and the first
/// choice writes a real one.
public struct GeneralTheme: Codable, Sendable, Equatable {
    /// Unique id, matching the JSON file's stem. A light/dark pair sharing a
    /// display name still needs two distinct names ("anura", "anura-dark").
    public let name: String
    /// Shown in the sidebar, with the appearance suffix appended. Renaming a
    /// theme changes this and not `name` — `name` is the filename and the value
    /// stored in settings, so moving it would break every reference to it.
    public var displayName: String
    public let appearance: ThemeAppearance

    public var text: String?
    public var invisibles: String?
    public var checkbox: String?
    public var link: String?
    /// Background of an ==highlighted== span. Opaque when a theme names one —
    /// `NSColor(hex:)` takes 6 digits, like `selection` — so a theme wanting the
    /// translucent look of the default should name a pale color outright.
    public var highlight: String?
    public var background: String?
    public var selection: String?
    public var cursor: String?

    public var syntaxTheme: String?

    /// The display name with its appearance spelled out — "Solarized (Dark)".
    ///
    /// Only worth showing when another theme shares the display name, which is
    /// `ThemeStore.label(for:)`'s job; a theme that is the only one of its name
    /// says "Tomorrow Night", not "Tomorrow Night (Dark)". Kept here because
    /// sorting wants one stable key per theme whether or not it is ambiguous.
    public var qualifiedLabel: String {
        "\(displayName) (\(appearance == .dark ? "Dark" : "Light"))"
    }

    /// The last-resort theme, used only if the bundled JSON cannot be read.
    /// Every color is `nil`, so the editor falls back to the platform defaults
    /// role by role and stays legible rather than rendering colorless.
    static func fallback(_ appearance: ThemeAppearance) -> GeneralTheme {
        GeneralTheme(name: "fallback", displayName: "Classic", appearance: appearance)
    }
}

// MARK: - Syntax Theme

/// Fenced-code-block colors. One hex per token scope; `plain` covers code the
/// scanner produced no token for. All required — a syntax theme with holes
/// would render half a code block in the wrong color.
public struct SyntaxTheme: Codable, Sendable, Equatable {
    public let name: String
    /// See `GeneralTheme.displayName` — renaming touches this, never `name`.
    public var displayName: String
    public let appearance: ThemeAppearance

    public var plain: String
    public var keyword: String
    public var command: String
    public var type: String
    public var attribute: String
    public var variable: String
    public var value: String
    public var number: String
    public var string: String
    public var comment: String

    /// See `GeneralTheme.qualifiedLabel`.
    public var qualifiedLabel: String {
        "\(displayName) (\(appearance == .dark ? "Dark" : "Light"))"
    }

    /// The hex for a token scope; `nil` = plain, un-tokenized code.
    /// The parameter is `token`, not `type`, so `case .type` can return the
    /// property of that name without the parameter shadowing it.
    func hex(_ token: CodeHighlighter.TokenType?) -> String {
        switch token {
        case nil:         return plain
        case .keyword:    return keyword
        case .command:    return command
        case .type:       return type
        case .attribute:  return attribute
        case .variable:   return variable
        case .value:      return value
        case .number:     return number
        case .string:     return string
        case .comment:    return comment
        }
    }
}
