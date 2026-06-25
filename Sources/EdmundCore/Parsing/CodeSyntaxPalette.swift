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
    static func hex(_ type: CodeHighlighter.TokenType?, dark: Bool) -> String {
        dark ? oneDark(type) : tomorrow(type)
    }

    /// Tomorrow (light).
    private static func tomorrow(_ type: CodeHighlighter.TokenType?) -> String {
        switch type {
        case nil:        return "#4d4d4c"
        case .keyword:   return "#8959a8"
        case .type:      return "#c18401"
        case .string:    return "#718c00"
        case .number:    return "#f5871f"
        case .comment:   return "#8e908c"
        case .function:  return "#4271ae"
        }
    }

    /// One Dark.
    private static func oneDark(_ type: CodeHighlighter.TokenType?) -> String {
        switch type {
        case nil:        return "#abb2bf"
        case .keyword:   return "#c678dd"
        case .type:      return "#e5c07b"
        case .string:    return "#98c379"
        case .number:    return "#d19a66"
        case .comment:   return "#5c6370"
        case .function:  return "#61afef"
        }
    }
}
