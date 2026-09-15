import Foundation

// MARK: - Themes
//
// Two JSON-backed theme kinds, plus a font preset, all loaded by `ThemeStore`:
//
//   - `GeneralTheme` colors the editor chrome (ink, page, selection, caret,
//     invisibles, checkbox, links).
//   - `SyntaxTheme` colors fenced code blocks — one hex per
//     `CodeHighlighter.TokenType`, plus `plain` for un-tokenized text.
//
// Both declare the appearance they are legible on, and the app keeps one active
// theme per appearance per kind, swapping on light ↔ dark.
//
// `FontTheme` below is typography, but it is not one of those two: it is a
// preset chosen globally in Settings ▸ Appearance. No editor theme names it, so
// the light↔dark switch cannot change the reader's typeface — that hazard came
// from the assignment, not from presets existing.
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
    /// The code-block page when a theme names none. The values Edmund has always
    /// drawn; kept here so Edit mode and Read mode's `--code-bg` cannot drift,
    /// which is what the comment on `EditorTextView.codeBlockBackground` was
    /// guarding by hand.
    public static func defaultBackgroundHex(dark: Bool) -> String {
        dark ? "#333333" : "#f4f4f4"
    }

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

    /// The page a fenced code block sits on. Optional, unlike the ten scope
    /// colors: a code theme is a set of inks first, and a theme that names no
    /// page gets the editor's own — which is what every theme written before
    /// this field did, and still does.
    ///
    /// It belongs to the code theme rather than the editor theme because the
    /// block is the code theme's subject: Solarized's cream and One Dark's
    /// charcoal are part of those designs, and pinning them to the editor theme
    /// would mean a code theme could never bring its own.
    public var background: String?

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

// MARK: - Font Theme

/// A typographic preset: both faces, their sizes and ligatures, the line
/// height, and the per-script cascade.
///
/// A *preset*, not a theme an editor theme names. One is chosen globally in
/// Settings ▸ Appearance and that is the only relation it has to anything —
/// nothing assigns it, nothing inherits it, and switching a color theme cannot
/// change it. It exists because per-script fonts make a typographic setup
/// large: eleven values before the nine scripts, thirty-two after, which is far
/// too much to rebuild by hand to move between a CJK writing setup and a
/// code-heavy one.
///
/// The five typographic fields are required, as `SyntaxTheme`'s colors are: a
/// font theme is a complete set. The later additions default instead, so a
/// theme written before they existed still loads.
public struct FontTheme: Codable, Sendable, Equatable {
    public let name: String
    /// See `GeneralTheme.displayName` — renaming touches this, never `name`.
    public var displayName: String

    public var fontName: String
    public var fontSize: Double
    /// Empty means the system monospaced font, matching `EditorTheme`.
    public var monospaceFontName: String
    public var monospaceFontSize: Double
    /// A multiple of the body size, as Settings ▸ Appearance shows it.
    public var lineHeight: Double

    public var standardLigatures: Bool
    public var monospaceLigatures: Bool

    /// Per-script overrides: family, a multiple of the run's size, and whether
    /// the face's ligatures are on.
    ///
    /// Keyed by `FontCascadeScript.rawValue` rather than by the enum, so the
    /// JSON is an object someone can type — a dictionary with enum keys encodes
    /// as a flat `[key, value, key, value]` array, and these files are meant to
    /// be hand-authored. The `script*` accessors convert, and drop keys this
    /// build does not know, exactly as `EditorTheme.load` does for the same
    /// data in settings.
    public var cascade: [String: String]
    public var cascadeSizeRatios: [String: Double]
    /// Only the "off" entries matter; absent is on, as in `EditorTheme`.
    public var cascadeLigatures: [String: Bool]

    /// The cascade as `EditorTheme` holds it, unknown scripts dropped.
    public var scriptCascade: [FontCascadeScript: String] {
        var out: [FontCascadeScript: String] = [:]
        for (key, family) in cascade where !family.isEmpty {
            if let script = FontCascadeScript(rawValue: key) { out[script] = family }
        }
        return out
    }

    /// The ratios as `EditorTheme` holds them: unknown scripts dropped, and
    /// each clamped to the range the pane allows, so a hand-edited file cannot
    /// ask for a size the UI could never have produced.
    public var scriptSizeRatios: [FontCascadeScript: Double] {
        var out: [FontCascadeScript: Double] = [:]
        for (key, ratio) in cascadeSizeRatios {
            if let script = FontCascadeScript(rawValue: key) {
                out[script] = min(2.0, max(0.5, ratio))
            }
        }
        return out
    }

    public var scriptLigatures: [FontCascadeScript: Bool] {
        var out: [FontCascadeScript: Bool] = [:]
        for (key, on) in cascadeLigatures where !on {
            if let script = FontCascadeScript(rawValue: key) { out[script] = false }
        }
        return out
    }

    /// No appearance suffix, unlike the other two kinds: there is only ever one
    /// row per font theme.
    public var label: String { displayName }

    public init(name: String, displayName: String,
                fontName: String, fontSize: Double,
                monospaceFontName: String, monospaceFontSize: Double,
                lineHeight: Double,
                standardLigatures: Bool = true, monospaceLigatures: Bool = false,
                cascade: [String: String] = [:],
                cascadeSizeRatios: [String: Double] = [:],
                cascadeLigatures: [String: Bool] = [:]) {
        self.name = name
        self.displayName = displayName
        self.fontName = fontName
        self.fontSize = fontSize
        self.monospaceFontName = monospaceFontName
        self.monospaceFontSize = monospaceFontSize
        self.lineHeight = lineHeight
        self.standardLigatures = standardLigatures
        self.monospaceLigatures = monospaceLigatures
        self.cascade = cascade
        self.cascadeSizeRatios = cascadeSizeRatios
        self.cascadeLigatures = cascadeLigatures
    }

    /// Written by hand because the synthesized decoder ignores a property's
    /// default value: a missing key is an error to it, so every bundled and
    /// hand-authored theme predating the later fields would stop loading.
    /// The five original fields stay required — a font theme is a complete set,
    /// and a file without a body face is a file with a typo in it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        displayName = try c.decode(String.self, forKey: .displayName)
        fontName = try c.decode(String.self, forKey: .fontName)
        fontSize = try c.decode(Double.self, forKey: .fontSize)
        monospaceFontName = try c.decode(String.self, forKey: .monospaceFontName)
        monospaceFontSize = try c.decode(Double.self, forKey: .monospaceFontSize)
        lineHeight = try c.decode(Double.self, forKey: .lineHeight)
        standardLigatures = try c.decodeIfPresent(Bool.self, forKey: .standardLigatures) ?? true
        monospaceLigatures = try c.decodeIfPresent(Bool.self, forKey: .monospaceLigatures) ?? false
        cascade = try c.decodeIfPresent([String: String].self, forKey: .cascade) ?? [:]
        cascadeSizeRatios = try c.decodeIfPresent(
            [String: Double].self, forKey: .cascadeSizeRatios) ?? [:]
        cascadeLigatures = try c.decodeIfPresent(
            [String: Bool].self, forKey: .cascadeLigatures) ?? [:]
    }
}
