import AppKit

// MARK: - Code Block Rendering
//
// A tinted background box (matching Read mode's `--code-bg`, see
// HTMLTheme.swift) for an inactive *fenced* code block. The fence lines get
// the same treatment as blockquote's `>` marker: normal-size text that draws
// no ink (clear color, NOT hiddenFont — see the delimiter loop in
// EditorTextView+Rendering.swift), so each fence line keeps its natural
// height and doubles as the box's top/bottom breathing room. When the caret
// is inside (cursorInToken), the caller skips this and the raw fences show
// dimmed, exactly like callouts and block quotes. Indented code blocks keep
// their plain monospace rendering — no fence lines to absorb a box's
// breathing room, and no box wanted there.

extension EditorTextView {

    /// Background tint for a code block's box: the active code theme's page
    /// when it names one, else the shipped default. Matches Read mode's
    /// `--code-bg` (HTMLTheme.swift) so Edit and Read mode agree — both now read
    /// the same theme and the same fallback.
    var codeBlockBackground: NSColor {
        let dark = isDarkAppearance
        let hex = ThemeStore.shared.syntax(dark: dark)?.background
            ?? SyntaxTheme.defaultBackgroundHex(dark: dark)
        // `NSColor(hex:)` decodes sRGB, which is what Read mode's CSS means by
        // the same string — the two land on the same pixel.
        return NSColor(hex: hex) ?? NSColor(calibratedWhite: dark ? 0.2 : 0.96, alpha: 1)
    }

    /// Applies the background box to an inactive fenced code block. Only
    /// called from styleBlock's `.codeBlock` case when `!cursorInToken`;
    /// the fence ink itself is cleared by the delimiter loop.
    func styleCodeBlockBox(_ result: NSMutableAttributedString,
                           span: SyntaxHighlighter.Span,
                           language: String?) {
        guard span.fullRange.upperBound <= result.length,
              !span.delimiterRanges.isEmpty else { return }
        let box = BlockDecoration(.box(background: codeBlockBackground, borderColor: nil,
                                       borderEdges: [], borderWidth: 0, bottomPad: 0))
        result.addAttribute(.blockDecoration, value: box, range: span.fullRange)
        result.addAttribute(.paragraphStyle, value: codeBlockParagraphStyle, range: span.fullRange)

        // Label plumbing: the opening fence line carries the display language
        // ("" when the fence names none) and shaves the box's top padding;
        // the second row paints the actual label, reaching up over the fence
        // row (see `.codeBlockLabelAnchor` for why the fence fragment can't).
        let ns = result.string as NSString
        let trimmed = language?.trimmingCharacters(in: .whitespaces) ?? ""
        let firstLine = ns.lineRange(for: NSRange(location: span.fullRange.location, length: 0))
        result.addAttribute(.codeBlockLabel, value: trimmed.capitalized,
                            range: NSIntersectionRange(firstLine, span.fullRange))
        if !trimmed.isEmpty, firstLine.upperBound < span.fullRange.upperBound {
            let secondLine = ns.lineRange(for: NSRange(location: firstLine.upperBound, length: 0))
            result.addAttribute(.codeBlockLabelAnchor, value: trimmed.capitalized,
                                range: NSIntersectionRange(secondLine, span.fullRange))
        }
    }

    /// Text inset for a code block's box (matches Read mode's `padding: 12px
    /// 14px`). No hanging indent — code has no per-line marker to hang under.
    private var codeBlockParagraphStyle: NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = bodyParagraphStyle.lineSpacing
        ps.firstLineHeadIndent = 12
        ps.headIndent = 12
        ps.tailIndent = -12
        return ps
    }
}
