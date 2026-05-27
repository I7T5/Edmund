import Testing
import Foundation
@testable import MarkdownEditorCore

// MARK: - Bold

@Suite("SyntaxHighlighter — Bold")
struct BoldTests {

    @Test("**bold** produces a bold span")
    func doubleStar() {
        let spans = SyntaxHighlighter.parse("**bold**")
        #expect(spans.count == 1)
        let s = spans[0]
        #expect(s.kind == .bold)
        #expect(s.fullRange == NSRange(location: 0, length: 8))
        #expect(s.contentRange == NSRange(location: 2, length: 4))
        #expect(s.delimiterRanges.count == 2)
        #expect(s.delimiterRanges[0] == NSRange(location: 0, length: 2))
        #expect(s.delimiterRanges[1] == NSRange(location: 6, length: 2))
    }

    @Test("__bold__ with underscores")
    func doubleUnderscore() {
        let spans = SyntaxHighlighter.parse("__bold__")
        #expect(spans.count == 1)
        #expect(spans[0].kind == .bold)
        #expect(spans[0].contentRange == NSRange(location: 2, length: 4))
    }

    @Test("text **bold** text has correct offset")
    func boldInMiddle() {
        let spans = SyntaxHighlighter.parse("hello **world** end")
        #expect(spans.count == 1)
        #expect(spans[0].kind == .bold)
        #expect(spans[0].fullRange == NSRange(location: 6, length: 9))
        #expect(spans[0].contentRange == NSRange(location: 8, length: 5))
    }
}

// MARK: - Italic

@Suite("SyntaxHighlighter — Italic")
struct ItalicTests {

    @Test("*italic* produces an italic span")
    func singleStar() {
        let spans = SyntaxHighlighter.parse("*italic*")
        #expect(spans.count == 1)
        let s = spans[0]
        #expect(s.kind == .italic)
        #expect(s.fullRange == NSRange(location: 0, length: 8))
        #expect(s.contentRange == NSRange(location: 1, length: 6))
    }

    @Test("_italic_ with underscore")
    func singleUnderscore() {
        let spans = SyntaxHighlighter.parse("_italic_")
        #expect(spans.count == 1)
        #expect(spans[0].kind == .italic)
    }
}

// MARK: - Bold + Italic

@Suite("SyntaxHighlighter — Bold+Italic")
struct BoldItalicTests {

    @Test("***text*** produces boldItalic")
    func tripleStar() {
        let spans = SyntaxHighlighter.parse("***both***")
        #expect(spans.count == 1)
        let s = spans[0]
        #expect(s.kind == .boldItalic)
        #expect(s.contentRange == NSRange(location: 3, length: 4))
        #expect(s.delimiterRanges[0] == NSRange(location: 0, length: 3))
        #expect(s.delimiterRanges[1] == NSRange(location: 7, length: 3))
    }

    @Test("___text___ with underscores")
    func tripleUnderscore() {
        let spans = SyntaxHighlighter.parse("___both___")
        #expect(spans.count == 1)
        #expect(spans[0].kind == .boldItalic)
    }
}

// MARK: - Code

@Suite("SyntaxHighlighter — Code")
struct CodeTests {

    @Test("`code` produces a code span")
    func inlineCode() {
        let spans = SyntaxHighlighter.parse("`code`")
        #expect(spans.count == 1)
        let s = spans[0]
        #expect(s.kind == .code)
        #expect(s.contentRange == NSRange(location: 1, length: 4))
        #expect(s.delimiterRanges[0] == NSRange(location: 0, length: 1))
        #expect(s.delimiterRanges[1] == NSRange(location: 5, length: 1))
    }

    @Test("Code spans suppress inner parsing")
    func codeOpaqueToMarkdown() {
        let spans = SyntaxHighlighter.parse("`**not bold**`")
        #expect(spans.count == 1)
        #expect(spans[0].kind == .code)
    }
}

// MARK: - Headings

@Suite("SyntaxHighlighter — Headings")
struct HeadingTests {

    @Test("# Heading produces level-1 heading")
    func h1() {
        let spans = SyntaxHighlighter.parse("# Hello")
        #expect(spans.count == 1)
        let s = spans[0]
        #expect(s.kind == .heading(1))
        #expect(s.contentRange == NSRange(location: 2, length: 5))
        #expect(s.delimiterRanges[0] == NSRange(location: 0, length: 2))
    }

    @Test("## Heading produces level-2")
    func h2() {
        let spans = SyntaxHighlighter.parse("## Sub")
        #expect(spans.count == 1)
        #expect(spans[0].kind == .heading(2))
    }

    @Test("### Heading produces level-3")
    func h3() {
        let spans = SyntaxHighlighter.parse("### Sub sub")
        #expect(spans.count == 1)
        #expect(spans[0].kind == .heading(3))
    }

    @Test("###### deepest heading is level 6")
    func h6() {
        let spans = SyntaxHighlighter.parse("###### Deep")
        #expect(spans.count == 1)
        #expect(spans[0].kind == .heading(6))
    }

    @Test("# without space is not a heading")
    func noSpace() {
        let spans = SyntaxHighlighter.parse("#notaheading")
        #expect(spans.isEmpty)
    }

    @Test("Heading suppresses inline parsing in its range")
    func headingSuppressesInline() {
        let spans = SyntaxHighlighter.parse("# **Bold heading**")
        #expect(spans.count == 1)
        #expect(spans[0].kind == .heading(1))
    }
}

// MARK: - Priority & Overlap

@Suite("SyntaxHighlighter — Priority")
struct PriorityTests {

    @Test("*** is matched as boldItalic, not bold + italic")
    func tripleStarPriority() {
        let spans = SyntaxHighlighter.parse("***text***")
        #expect(spans.count == 1)
        #expect(spans[0].kind == .boldItalic)
    }

    @Test("Multiple spans in one line")
    func multipleSpans() {
        let spans = SyntaxHighlighter.parse("**bold** and *italic*")
        #expect(spans.count == 2)
        #expect(spans[0].kind == .bold)
        #expect(spans[1].kind == .italic)
    }

    @Test("Code before bold: code wins on its range")
    func codeThenBold() {
        let spans = SyntaxHighlighter.parse("`code` **bold**")
        #expect(spans.count == 2)
        #expect(spans[0].kind == .code)
        #expect(spans[1].kind == .bold)
    }
}

// MARK: - Edge Cases

@Suite("SyntaxHighlighter — Edge Cases")
struct EdgeCaseTests {

    @Test("Empty string produces no spans")
    func emptyString() {
        #expect(SyntaxHighlighter.parse("").isEmpty)
    }

    @Test("Plain text produces no spans")
    func plainText() {
        #expect(SyntaxHighlighter.parse("hello world").isEmpty)
    }

    @Test("Unmatched * produces no span")
    func unmatchedStar() {
        #expect(SyntaxHighlighter.parse("*no close").isEmpty)
    }

    @Test("Unmatched ** produces no span")
    func unmatchedDoubleStar() {
        #expect(SyntaxHighlighter.parse("**no close").isEmpty)
    }

    @Test("Adjacent bold spans")
    func adjacentBold() {
        let spans = SyntaxHighlighter.parse("**a** **b**")
        #expect(spans.count == 2)
        #expect(spans[0].kind == .bold)
        #expect(spans[1].kind == .bold)
    }
}

// MARK: - Mismatched Delimiters (CommonMark behavior)
//
// Per CommonMark spec, mismatched delimiters match the smaller count.
// e.g. **hi* → literal * + italic hi (the single * pair matches).
// This matches Apple's AttributedString(markdown:) behavior.

@Suite("SyntaxHighlighter — Mismatched Delimiters")
struct MismatchedDelimiterTests {

    @Test("**hi* → italic hi (single * pair matches, extra * is literal)")
    func doubleOpenSingleClose() {
        let spans = SyntaxHighlighter.parse("**hi*")
        let italics = spans.filter { $0.kind == .italic }
        #expect(italics.count == 1)
    }

    @Test("*hi** → italic hi (single * pair matches, extra * is literal)")
    func singleOpenDoubleClose() {
        let spans = SyntaxHighlighter.parse("*hi**")
        let italics = spans.filter { $0.kind == .italic }
        #expect(italics.count == 1)
    }

    @Test("***hi** → bold hi (double ** pair matches, extra * is literal)")
    func tripleOpenDoubleClose() {
        let spans = SyntaxHighlighter.parse("***hi**")
        let bolds = spans.filter { $0.kind == .bold }
        #expect(bolds.count == 1)
    }

    @Test("***hi* → italic hi (single * pair matches, extra ** is literal)")
    func tripleOpenSingleClose() {
        let spans = SyntaxHighlighter.parse("***hi*")
        let italics = spans.filter { $0.kind == .italic }
        #expect(italics.count == 1)
    }

    @Test("**hi*** → bold hi (double ** pair matches, extra * is literal)")
    func doubleOpenTripleClose() {
        let spans = SyntaxHighlighter.parse("**hi***")
        let bolds = spans.filter { $0.kind == .bold }
        #expect(bolds.count == 1)
    }

    @Test("*hi*** → italic hi (single * pair matches, extra ** is literal)")
    func singleOpenTripleClose() {
        let spans = SyntaxHighlighter.parse("*hi***")
        let italics = spans.filter { $0.kind == .italic }
        #expect(italics.count == 1)
    }
}

// MARK: - Links

@Suite("SyntaxHighlighter — Strikethrough")
struct StrikethroughTests {

    @Test("~~text~~ produces a strikethrough span")
    func basic() {
        let spans = SyntaxHighlighter.parse("~~deleted~~")
        #expect(spans.count == 1)
        let s = spans[0]
        #expect(s.kind == .strikethrough)
        #expect(s.fullRange == NSRange(location: 0, length: 11))
        #expect(s.contentRange == NSRange(location: 2, length: 7))
        #expect(s.delimiterRanges.count == 2)
        #expect(s.delimiterRanges[0] == NSRange(location: 0, length: 2))
        #expect(s.delimiterRanges[1] == NSRange(location: 9, length: 2))
    }

    @Test("Strikethrough delimiter is ~~")
    func delimiters() {
        let spans = SyntaxHighlighter.parse("~~hello~~")
        #expect(spans[0].delimiterRanges[0].length == 2)
        #expect(spans[0].delimiterRanges[1].length == 2)
    }
}

@Suite("SyntaxHighlighter — Highlight")
struct HighlightTests {

    @Test("==text== produces a highlight span")
    func basic() {
        let spans = SyntaxHighlighter.parse("==highlighted==")
        #expect(spans.count == 1)
        let s = spans[0]
        #expect(s.kind == .highlight)
        #expect(s.fullRange == NSRange(location: 0, length: 15))
        #expect(s.contentRange == NSRange(location: 2, length: 11))
        #expect(s.delimiterRanges.count == 2)
        #expect(s.delimiterRanges[0] == NSRange(location: 0, length: 2))
        #expect(s.delimiterRanges[1] == NSRange(location: 13, length: 2))
    }

    @Test("Highlight inside code is ignored")
    func insideCode() {
        let spans = SyntaxHighlighter.parse("`==nope==`")
        let highlights = spans.filter { $0.kind == .highlight }
        #expect(highlights.isEmpty)
    }
}

@Suite("SyntaxHighlighter — Links")
struct LinkTests {

    @Test("Basic link [text](url) produces a link span")
    func basicLink() {
        let spans = SyntaxHighlighter.parse("[hello](https://example.com)")
        let links = spans.filter { if case .link = $0.kind { return true }; return false }
        #expect(links.count == 1)
        #expect(links[0].contentRange == NSRange(location: 1, length: 5))  // "hello"
    }

    @Test("Link destination is captured")
    func linkDestination() {
        let spans = SyntaxHighlighter.parse("[click](https://example.com)")
        let links = spans.filter { if case .link = $0.kind { return true }; return false }
        #expect(links.count == 1)
        if case .link(let dest) = links[0].kind {
            #expect(dest == "https://example.com")
        }
    }

    @Test("Link delimiters are [ and ](url)")
    func linkDelimiters() {
        let spans = SyntaxHighlighter.parse("[hi](url)")
        let links = spans.filter { if case .link = $0.kind { return true }; return false }
        #expect(links.count == 1)
        #expect(links[0].delimiterRanges.count == 2)
        // First delimiter: "["
        #expect(links[0].delimiterRanges[0] == NSRange(location: 0, length: 1))
        // Second delimiter: "](url)"
        #expect(links[0].delimiterRanges[1] == NSRange(location: 3, length: 6))
    }

    @Test("Bold inside link text is detected")
    func boldInsideLink() {
        let spans = SyntaxHighlighter.parse("[**bold**](url)")
        let links = spans.filter { if case .link = $0.kind { return true }; return false }
        let bolds = spans.filter { $0.kind == .bold }
        #expect(links.count == 1)
        #expect(bolds.count == 1)
    }
}

// MARK: - Blockquotes

@Suite("SyntaxHighlighter — Blockquotes")
struct BlockquoteTests {

    @Test("Basic blockquote > text produces a blockquote span")
    func basicBlockquote() {
        let spans = SyntaxHighlighter.parse("> hello")
        let quotes = spans.filter { $0.kind == .blockquote }
        #expect(quotes.count == 1)
    }

    @Test("Blockquote delimiter is the > prefix")
    func blockquoteDelimiter() {
        let spans = SyntaxHighlighter.parse("> hello")
        let quotes = spans.filter { $0.kind == .blockquote }
        #expect(quotes.count == 1)
        #expect(quotes[0].delimiterRanges.count >= 1)
        // Content should be "hello"
        #expect(quotes[0].contentRange.length == 5)
    }

    @Test("Bold inside blockquote is detected")
    func boldInsideBlockquote() {
        let spans = SyntaxHighlighter.parse("> **bold**")
        let quotes = spans.filter { $0.kind == .blockquote }
        let bolds = spans.filter { $0.kind == .bold }
        #expect(quotes.count == 1)
        #expect(bolds.count == 1)
    }
}

// MARK: - List Items

@Suite("SyntaxHighlighter — List Items")
struct ListItemTests {

    @Test("Unordered list item - text produces a listItem span")
    func unorderedListItem() {
        let spans = SyntaxHighlighter.parse("- hello")
        let items = spans.filter { if case .listItem = $0.kind { return true }; return false }
        #expect(items.count == 1)
        if case .listItem(let ordered, _) = items[0].kind {
            #expect(!ordered)
        }
    }

    @Test("Ordered list item 1. text produces a listItem span")
    func orderedListItem() {
        let spans = SyntaxHighlighter.parse("1. hello")
        let items = spans.filter { if case .listItem = $0.kind { return true }; return false }
        #expect(items.count == 1)
        if case .listItem(let ordered, _) = items[0].kind {
            #expect(ordered)
        }
    }

    @Test("Unordered list delimiter is - prefix")
    func unorderedDelimiter() {
        let spans = SyntaxHighlighter.parse("- hello")
        let items = spans.filter { if case .listItem = $0.kind { return true }; return false }
        #expect(items.count == 1)
        #expect(items[0].contentRange.length == 5)  // "hello"
    }

    @Test("Bold inside list item is detected")
    func boldInsideListItem() {
        let spans = SyntaxHighlighter.parse("- **bold**")
        let items = spans.filter { if case .listItem = $0.kind { return true }; return false }
        let bolds = spans.filter { $0.kind == .bold }
        #expect(items.count == 1)
        #expect(bolds.count == 1)
    }

    @Test("Unchecked todo item - [ ] produces listItem with unchecked checkbox")
    func uncheckedTodo() {
        let spans = SyntaxHighlighter.parse("- [ ] todo")
        let items = spans.filter { if case .listItem = $0.kind { return true }; return false }
        #expect(items.count == 1)
        if case .listItem(_, let checkbox) = items[0].kind {
            #expect(checkbox == .unchecked)
        } else {
            #expect(Bool(false), "Expected listItem")
        }
    }

    @Test("Checked todo item - [x] produces listItem with checked checkbox")
    func checkedTodo() {
        let spans = SyntaxHighlighter.parse("- [x] done")
        let items = spans.filter { if case .listItem = $0.kind { return true }; return false }
        #expect(items.count == 1)
        if case .listItem(_, let checkbox) = items[0].kind {
            #expect(checkbox == .checked)
        } else {
            #expect(Bool(false), "Expected listItem")
        }
    }
}

// MARK: - Thematic Break

@Suite("SyntaxHighlighter — Thematic Break")
struct ThematicBreakTests {

    @Test("--- produces a thematicBreak span")
    func tripleDash() {
        let spans = SyntaxHighlighter.parse("---")
        #expect(spans.count == 1)
        let s = spans[0]
        #expect(s.kind == .thematicBreak)
        #expect(s.fullRange == NSRange(location: 0, length: 3))
        #expect(s.contentRange == s.fullRange)
        #expect(s.delimiterRanges == [s.fullRange])
    }

    @Test("*** produces a thematicBreak span")
    func tripleAsterisk() {
        let spans = SyntaxHighlighter.parse("***")
        #expect(spans.count == 1)
        #expect(spans[0].kind == .thematicBreak)
    }

    @Test("___ produces a thematicBreak span")
    func tripleUnderscore() {
        let spans = SyntaxHighlighter.parse("___")
        #expect(spans.count == 1)
        #expect(spans[0].kind == .thematicBreak)
    }

    @Test("Thematic break with extra dashes")
    func extraDashes() {
        let spans = SyntaxHighlighter.parse("-----")
        #expect(spans.count == 1)
        #expect(spans[0].kind == .thematicBreak)
        #expect(spans[0].fullRange == NSRange(location: 0, length: 5))
    }

    @Test("Thematic break between paragraphs")
    func betweenParagraphs() {
        let text = "above\n\n---\n\nbelow"
        let spans = SyntaxHighlighter.parse(text)
        let breaks = spans.filter { $0.kind == .thematicBreak }
        #expect(breaks.count == 1)
    }
}

// MARK: - Images

@Suite("SyntaxHighlighter — Images")
struct ImageTests {

    @Test("![alt](url) produces an image span")
    func basicImage() {
        let spans = SyntaxHighlighter.parse("![alt text](https://example.com/img.png)")
        let images = spans.filter {
            if case .image = $0.kind { return true }
            return false
        }
        #expect(images.count == 1)
        if case .image(let dest) = images[0].kind {
            #expect(dest == "https://example.com/img.png")
        }
    }

    @Test("Image content range covers alt text")
    func imageContentRange() {
        let text = "![alt](url)"
        let spans = SyntaxHighlighter.parse(text)
        let images = spans.filter {
            if case .image = $0.kind { return true }
            return false
        }
        #expect(images.count == 1)
        let content = (text as NSString).substring(with: images[0].contentRange)
        #expect(content == "alt")
    }

    @Test("Image delimiter ranges cover ![ and ](url)")
    func imageDelimiterRanges() {
        let text = "![alt](url)"
        let spans = SyntaxHighlighter.parse(text)
        let images = spans.filter {
            if case .image = $0.kind { return true }
            return false
        }
        #expect(images.count == 1)
        #expect(images[0].delimiterRanges.count == 2)
        // Opening delimiter: "!["
        let openDelim = (text as NSString).substring(with: images[0].delimiterRanges[0])
        #expect(openDelim == "![")
        // Closing delimiter: "](url)"
        let closeDelim = (text as NSString).substring(with: images[0].delimiterRanges[1])
        #expect(closeDelim == "](url)")
    }

    @Test("Image with empty alt text")
    func emptyAlt() {
        let spans = SyntaxHighlighter.parse("![](url)")
        let images = spans.filter {
            if case .image = $0.kind { return true }
            return false
        }
        #expect(images.count == 1)
    }

    @Test("Image mixed with text")
    func imageInText() {
        let spans = SyntaxHighlighter.parse("see ![pic](url) here")
        let images = spans.filter {
            if case .image = $0.kind { return true }
            return false
        }
        #expect(images.count == 1)
    }
}

// MARK: - Line Break

@Suite("SyntaxHighlighter — Line Break")
struct LineBreakTests {

    @Test("Trailing backslash produces lineBreak span")
    func trailingBackslash() {
        let spans = SyntaxHighlighter.parse("hello\\")
        let breaks = spans.filter { $0.kind == .lineBreak }
        #expect(breaks.count == 1)
        #expect(breaks[0].fullRange == NSRange(location: 5, length: 1))
    }

    @Test("No trailing backslash means no lineBreak")
    func noBackslash() {
        let spans = SyntaxHighlighter.parse("hello")
        let breaks = spans.filter { $0.kind == .lineBreak }
        #expect(breaks.count == 0)
    }

    @Test("Double backslash is escaped, not a lineBreak")
    func escapedBackslash() {
        let spans = SyntaxHighlighter.parse("hello\\\\")
        let breaks = spans.filter { $0.kind == .lineBreak }
        #expect(breaks.count == 0)
    }

    @Test("Multi-line text does not produce lineBreak")
    func multiLine() {
        let spans = SyntaxHighlighter.parse("hello\\\nworld")
        let breaks = spans.filter { $0.kind == .lineBreak }
        #expect(breaks.count == 0)
    }

    @Test("LineBreak delimiter range is the backslash")
    func delimiterRange() {
        let spans = SyntaxHighlighter.parse("text\\")
        let breaks = spans.filter { $0.kind == .lineBreak }
        #expect(breaks.count == 1)
        #expect(breaks[0].delimiterRanges == [NSRange(location: 4, length: 1)])
    }
}
