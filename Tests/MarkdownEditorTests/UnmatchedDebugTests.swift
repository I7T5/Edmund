import Testing
import Foundation
@testable import MarkdownEditorCore

// MARK: - Unmatched Emphasis Delimiters

@Suite("SyntaxHighlighter — Unmatched Delimiters")
struct UnmatchedDelimiterTests {

    @Test("**here* trims opening delimiter to single *")
    func doubleStarHereStar() {
        let spans = SyntaxHighlighter.parse("**here*")
        #expect(spans.count == 1)
        let s = spans[0]
        #expect(s.kind == .italic)
        #expect(s.fullRange == NSRange(location: 1, length: 6))
        #expect(s.contentRange == NSRange(location: 2, length: 4))
        #expect(s.delimiterRanges == [
            NSRange(location: 1, length: 1),
            NSRange(location: 6, length: 1),
        ])
    }

    @Test("_here__ trims closing delimiter to single _")
    func underscoreHereDoubleUnderscore() {
        let spans = SyntaxHighlighter.parse("_here__")
        #expect(spans.count == 1)
        let s = spans[0]
        #expect(s.kind == .italic)
        #expect(s.fullRange == NSRange(location: 0, length: 6))
        #expect(s.contentRange == NSRange(location: 1, length: 4))
        #expect(s.delimiterRanges == [
            NSRange(location: 0, length: 1),
            NSRange(location: 5, length: 1),
        ])
    }

    @Test("***bold** trims opening delimiter to **")
    func tripleStarBoldDoubleStar() {
        let spans = SyntaxHighlighter.parse("***bold**")
        #expect(spans.count == 1)
        let s = spans[0]
        #expect(s.kind == .bold)
        #expect(s.fullRange == NSRange(location: 1, length: 8))
        #expect(s.contentRange == NSRange(location: 3, length: 4))
        #expect(s.delimiterRanges == [
            NSRange(location: 1, length: 2),
            NSRange(location: 7, length: 2),
        ])
    }

    @Test("***here* trims opening delimiter to single *")
    func tripleStarHereStar() {
        let spans = SyntaxHighlighter.parse("***here*")
        #expect(spans.count == 1)
        let s = spans[0]
        #expect(s.kind == .italic)
        #expect(s.fullRange == NSRange(location: 2, length: 6))
        #expect(s.contentRange == NSRange(location: 3, length: 4))
        #expect(s.delimiterRanges == [
            NSRange(location: 2, length: 1),
            NSRange(location: 7, length: 1),
        ])
    }

    @Test("****here*** trims opening delimiter to ***")
    func quadStarHereTripleStar() {
        let spans = SyntaxHighlighter.parse("****here***")
        #expect(spans.count == 1)
        let s = spans[0]
        #expect(s.kind == .boldItalic)
        #expect(s.fullRange == NSRange(location: 1, length: 10))
        #expect(s.contentRange == NSRange(location: 4, length: 4))
        #expect(s.delimiterRanges == [
            NSRange(location: 1, length: 3),
            NSRange(location: 8, length: 3),
        ])
    }

    @Test("Matched delimiters are unchanged")
    func matchedDelimitersUnchanged() {
        let bold = SyntaxHighlighter.parse("**bold**")
        #expect(bold[0].fullRange == NSRange(location: 0, length: 8))
        #expect(bold[0].delimiterRanges[0] == NSRange(location: 0, length: 2))

        let italic = SyntaxHighlighter.parse("*italic*")
        #expect(italic[0].fullRange == NSRange(location: 0, length: 8))
        #expect(italic[0].delimiterRanges[0] == NSRange(location: 0, length: 1))

        let bi = SyntaxHighlighter.parse("***both***")
        #expect(bi[0].fullRange == NSRange(location: 0, length: 10))
        #expect(bi[0].delimiterRanges[0] == NSRange(location: 0, length: 3))
    }
}
