import AppKit

// MARK: - Code Block Syntax Highlighting
//
// Colors a fenced code block's content from `CodeHighlighter` tokens, using the
// Tomorrow palette in light appearance and One Dark in dark. Only foregrounds
// are themed — the block keeps the editor's background — so each palette is
// paired with the appearance whose background it's legible on.

extension EditorTextView {

    private var prefersDarkCodeTheme: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// The `NSColor` for a token kind (`nil` = plain code) in the current
    /// appearance, derived from the shared `CodeSyntaxPalette` hexes so the
    /// editor and Read mode / PDF export color tokens identically.
    private func codeColor(_ type: CodeHighlighter.TokenType?) -> NSColor {
        NSColor(hex: CodeSyntaxPalette.hex(type, dark: prefersDarkCodeTheme)) ?? .textColor
    }

    /// Applies syntax colors to a code block's content range in place.
    func highlightCodeBlock(_ result: NSMutableAttributedString,
                            contentRange: NSRange, language: String?) {
        guard contentRange.length > 0, contentRange.upperBound <= result.length else { return }

        // Plain code text first; token colors paint over it.
        result.addAttribute(.foregroundColor, value: codeColor(nil), range: contentRange)

        let code = (result.string as NSString).substring(with: contentRange)
        for token in CodeHighlighter.tokenize(code, language: language) {
            let abs = NSRange(location: contentRange.location + token.range.location,
                              length: token.range.length)
            guard abs.upperBound <= result.length else { continue }
            result.addAttribute(.foregroundColor, value: codeColor(token.type), range: abs)
        }
    }
}
