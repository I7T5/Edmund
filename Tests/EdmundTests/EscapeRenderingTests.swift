import Testing
import Foundation
import AppKit
@testable import EdmundCore

// Backslash escapes: `\*`, `\$`, etc. The backslash is hidden when the caret is
// outside the token and dimmed when inside; the escaped char renders literally.

@Suite("SyntaxHighlighter — Escapes")
struct EscapeParseTests {

    private func escapes(_ text: String) -> [SyntaxHighlighter.Span] {
        SyntaxHighlighter.parse(text).filter { if case .escape = $0.kind { return true }; return false }
    }

    @Test("`\\*` yields one escape: backslash delimiter, `*` content")
    func basic() {
        let spans = escapes("a \\* b")
        #expect(spans.count == 1)
        let s = spans[0]
        #expect(s.fullRange == NSRange(location: 2, length: 2))
        #expect(s.delimiterRanges == [NSRange(location: 2, length: 1)])
        #expect(s.contentRange == NSRange(location: 3, length: 1))
        // The escape suppresses emphasis, so no italic/bold span is produced.
        let all = SyntaxHighlighter.parse("a \\* b")
        #expect(!all.contains { if case .italic = $0.kind { return true }; return false })
    }

    @Test("`\\\\` is a single escape, not a trailing line break")
    func doubleBackslash() {
        let all = SyntaxHighlighter.parse("\\\\")
        let esc = all.filter { if case .escape = $0.kind { return true }; return false }
        #expect(esc.count == 1)
        #expect(esc[0].fullRange == NSRange(location: 0, length: 2))
        #expect(!all.contains { if case .lineBreak = $0.kind { return true }; return false })
    }

    @Test("No escape inside an inline code span")
    func insideCode() {
        #expect(escapes("`a\\*b`").isEmpty)
    }

    @Test("No escape inside inline math (backslash is a LaTeX command)")
    func insideMath() {
        #expect(escapes("$\\alpha$").isEmpty)
    }

    @Test("A backslash before a non-escapable char is not an escape")
    func nonEscapable() {
        #expect(escapes("a\\b").isEmpty)
    }

    @Test("Trailing `\\` stays a line break, not an escape")
    func trailingBackslash() {
        let all = SyntaxHighlighter.parse("foo\\")
        #expect(all.contains { if case .lineBreak = $0.kind { return true }; return false })
        #expect(!all.contains { if case .escape = $0.kind { return true }; return false })
    }
}

@Suite("Rendering — Escapes")
@MainActor
struct EscapeRenderingTests {

    @Test("Inactive: backslash hidden, escaped char visible")
    func inactiveHidesBackslash() {
        let editor = makeEditor()
        let styled = editor.styleBlock("a \\* b", cursorPosition: nil)
        #expect(isHidden(at: 2, in: styled))    // the backslash
        #expect(!isHidden(at: 3, in: styled))   // the literal `*`
    }

    @Test("Active: backslash dimmed, not hidden")
    func activeDimsBackslash() {
        let editor = makeEditor()
        let styled = editor.styleBlock("a \\* b", cursorPosition: 3)
        #expect(isDimmed(at: 2, in: styled))
        #expect(!isHidden(at: 2, in: styled))
    }
}
