import AppKit

// MARK: - Code Block Syntax Highlighting
//
// Colors a fenced code block's content from `CodeHighlighter` tokens, using the
// Tomorrow palette in light appearance and One Dark in dark. Only foregrounds
// are themed — the block keeps the editor's background — so each palette is
// paired with the appearance whose background it's legible on.

/// Foreground colors for the six highlighted token kinds plus plain code.
private struct CodePalette {
    let plain, keyword, type, string, number, comment, function: NSColor

    func color(for type: CodeHighlighter.TokenType) -> NSColor {
        switch type {
        case .keyword:  return keyword
        case .type:     return self.type
        case .string:   return string
        case .number:   return number
        case .comment:  return comment
        case .function: return function
        }
    }

    /// Tomorrow (light).
    static let tomorrow = CodePalette(
        plain:    NSColor(hex: "#4d4d4c") ?? .textColor,
        keyword:  NSColor(hex: "#8959a8") ?? .systemPurple,
        type:     NSColor(hex: "#c18401") ?? .systemYellow,
        string:   NSColor(hex: "#718c00") ?? .systemGreen,
        number:   NSColor(hex: "#f5871f") ?? .systemOrange,
        comment:  NSColor(hex: "#8e908c") ?? .secondaryLabelColor,
        function: NSColor(hex: "#4271ae") ?? .systemBlue)

    /// One Dark.
    static let oneDark = CodePalette(
        plain:    NSColor(hex: "#abb2bf") ?? .textColor,
        keyword:  NSColor(hex: "#c678dd") ?? .systemPurple,
        type:     NSColor(hex: "#e5c07b") ?? .systemYellow,
        string:   NSColor(hex: "#98c379") ?? .systemGreen,
        number:   NSColor(hex: "#d19a66") ?? .systemOrange,
        comment:  NSColor(hex: "#5c6370") ?? .secondaryLabelColor,
        function: NSColor(hex: "#61afef") ?? .systemBlue)
}

extension EditorTextView {

    private var prefersDarkCodeTheme: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// Applies syntax colors to a code block's content range in place.
    func highlightCodeBlock(_ result: NSMutableAttributedString,
                            contentRange: NSRange, language: String?) {
        guard contentRange.length > 0, contentRange.upperBound <= result.length else { return }
        let palette = prefersDarkCodeTheme ? CodePalette.oneDark : CodePalette.tomorrow

        // Plain code text first; token colors paint over it.
        result.addAttribute(.foregroundColor, value: palette.plain, range: contentRange)

        let code = (result.string as NSString).substring(with: contentRange)
        for token in CodeHighlighter.tokenize(code, language: language) {
            let abs = NSRange(location: contentRange.location + token.range.location,
                              length: token.range.length)
            guard abs.upperBound <= result.length else { continue }
            result.addAttribute(.foregroundColor, value: palette.color(for: token.type), range: abs)
        }
    }
}
