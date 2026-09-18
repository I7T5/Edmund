import Foundation

// MARK: - Code Syntax Palette
//
// The single source of truth for fenced-code-block colors: the Tomorrow palette
// (light) and One Dark (dark), as plain hex strings with no AppKit dependency.
// Both consumers derive from these:
//   - the editor (`EditorTextView+CodeHighlighting`) builds `NSColor`s for the
//     TextKit attribute run,
//   - Read mode / PDF export (`HTMLTheme`) emits CSS `color` rules,
// so Edit mode and Read mode color identical tokens identically.

enum CodeSyntaxPalette {

    /// The hex color for a token kind (`nil` = plain, un-tokenized code text) in
    /// the given appearance. Only foregrounds are themed; the block keeps its
    /// background, so each palette is paired with the appearance it's legible on.
    ///
    /// Comes from the active `SyntaxTheme`. The compiled-in palettes below are
    /// the fallback for when no theme JSON can be read at all — without one,
    /// every code block would render colorless. They are also the parity oracle
    /// the theme tests check the bundled Tomorrow / One Dark JSON against, so
    /// the two can't drift.
    static func hex(_ type: CodeHighlighter.TokenType?, dark: Bool) -> String {
        if let theme = ThemeStore.shared.syntax(dark: dark) { return theme.hex(type) }
        return dark ? oneDark(type) : tomorrow(type)
    }

    /// The compiled-in palette, bypassing the active theme — the fallback path,
    /// exposed so the parity test can assert the bundled JSON still matches it.
    static func builtinHex(_ type: CodeHighlighter.TokenType?, dark: Bool) -> String {
        dark ? oneDark(type) : tomorrow(type)
    }

    /// Tomorrow (light).
    private static func tomorrow(_ type: CodeHighlighter.TokenType?) -> String {
        switch type {
        case nil:         return "#4d4d4c"
        case .keyword:    return "#8959a8"
        case .command:    return "#4271ae"
        case .type:       return "#c18401"
        case .attribute:  return "#3e999f"
        case .variable:   return "#c82829"
        case .value:      return "#986801"
        case .number:     return "#f5871f"
        case .string:     return "#718c00"
        case .comment:    return "#8e908c"
        }
    }

    /// One Dark.
    private static func oneDark(_ type: CodeHighlighter.TokenType?) -> String {
        switch type {
        case nil:         return "#abb2bf"
        case .keyword:    return "#c678dd"
        case .command:    return "#61afef"
        case .type:       return "#e5c07b"
        case .attribute:  return "#56b6c2"
        case .variable:   return "#e06c75"
        case .value:      return "#d19a66"
        case .number:     return "#d19a66"
        case .string:     return "#98c379"
        case .comment:    return "#5c6370"
        }
    }
}
