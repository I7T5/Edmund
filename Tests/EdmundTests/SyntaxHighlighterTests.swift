import Testing
import Foundation
@testable import EdmundCore

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

    @Test("``a`b`` uses 2-backtick delimiters (GFM §6.3)")
    func doubleBacktickCode() {
        let spans = SyntaxHighlighter.parse("``a`b``")
        #expect(spans.count == 1)
        let s = spans[0]
        #expect(s.kind == .code)
        #expect(s.delimiterRanges == [NSRange(location: 0, length: 2),
                                      NSRange(location: 5, length: 2)])
        #expect(s.contentRange == NSRange(location: 2, length: 3))   // "a`b"
    }

    @Test("`` ` `` keeps its padding spaces in contentRange (edit mode shows source)")
    func paddedBacktick() {
        let spans = SyntaxHighlighter.parse("`` ` ``")
        #expect(spans.count == 1)
        let s = spans[0]
        #expect(s.kind == .code)
        #expect(s.delimiterRanges == [NSRange(location: 0, length: 2),
                                      NSRange(location: 5, length: 2)])
        #expect(s.contentRange == NSRange(location: 2, length: 3))   // " ` "
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
        // No space after `#` ⇒ not an ATX heading. (It is an Obsidian `#tag`,
        // so the span list is not empty — just assert no heading.)
        #expect(!spans.contains { if case .heading = $0.kind { return true }; return false })
    }

    @Test("Setext === underline: content is the first line, delimiter the underline")
    func setextH1() {
        let spans = SyntaxHighlighter.parse("Title\n===")
        let headings = spans.filter { if case .heading = $0.kind { return true }; return false }
        #expect(headings.count == 1)
        let s = headings[0]
        #expect(s.kind == .heading(1))
        #expect(s.fullRange == NSRange(location: 0, length: 9))
        #expect(s.contentRange == NSRange(location: 0, length: 5))       // "Title"
        #expect(s.delimiterRanges == [NSRange(location: 6, length: 3)])  // "==="
    }

    @Test("Setext --- underline is level 2")
    func setextH2() {
        let spans = SyntaxHighlighter.parse("Title\n---")
        let headings = spans.filter { if case .heading = $0.kind { return true }; return false }
        #expect(headings.count == 1)
        #expect(headings[0].kind == .heading(2))
    }

    @Test("Setext content can span multiple lines (GFM Example 51)")
    func setextMultiLineContent() {
        let spans = SyntaxHighlighter.parse("Foo\nbar\n===")
        let headings = spans.filter { if case .heading = $0.kind { return true }; return false }
        #expect(headings.count == 1)
        let s = headings[0]
        #expect(s.kind == .heading(1))
        #expect(s.contentRange == NSRange(location: 0, length: 7))        // "Foo\nbar"
        #expect(s.delimiterRanges == [NSRange(location: 8, length: 3)])   // "==="
    }

    @Test("Heading descends into inline children (nested styling)")
    func headingDescendsInline() {
        let spans = SyntaxHighlighter.parse("# **Bold heading**")
        #expect(spans.count == 2)
        #expect(spans[0].kind == .heading(1))
        #expect(spans[1].kind == .bold)
        #expect(spans[1].contentRange == NSRange(location: 4, length: 12))
    }

    @Test("Setext heading descends into inline children too")
    func setextDescendsInline() {
        let spans = SyntaxHighlighter.parse("**Bold** title\n===")
        let kinds = spans.map(\.kind)
        #expect(kinds.contains(.heading(1)))
        #expect(kinds.contains(.bold))
    }

    @Test("ATX heading's optional closing sequence is a hidden second delimiter")
    func atxClosingSequence() {
        let spans = SyntaxHighlighter.parse("# foo ###")
        let s = spans[0]
        #expect(s.kind == .heading(1))
        #expect(s.delimiterRanges.count == 2)
        #expect(s.contentRange == NSRange(location: 2, length: 3))       // "foo"
        #expect(s.delimiterRanges[1] == NSRange(location: 5, length: 4)) // " ###"
    }

    @Test("A closing '#' with no preceding space stays in the content")
    func atxNoPrecedingSpaceNotClosing() {
        let spans = SyntaxHighlighter.parse("# foo#")
        let s = spans[0]
        #expect(s.delimiterRanges.count == 1)
        #expect(s.contentRange == NSRange(location: 2, length: 4))       // "foo#"
    }

    @Test("An all-hashes closing sequence with empty content is entirely delimiter")
    func atxEmptyHeadingAllDelimiter() {
        let spans = SyntaxHighlighter.parse("## ##")
        let s = spans[0]
        #expect(s.kind == .heading(2))
        #expect(s.delimiterRanges.count == 2)
        #expect(s.contentRange.length == 0)
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

    @Test("Single-char ==a== highlights")
    func singleChar() {
        let spans = SyntaxHighlighter.parse("==a==")
        #expect(spans.count == 1)
        #expect(spans[0].kind == .highlight)
        #expect(spans[0].contentRange == NSRange(location: 2, length: 1))
    }

    @Test("Whitespace-flanked content is not a highlight",
          arguments: ["== spaced ==", "==lead ==", "== trail=="])
    func flanking(_ text: String) {
        let highlights = SyntaxHighlighter.parse(text).filter { $0.kind == .highlight }
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
        let quotes = spans.filter { $0.kind == .blockquote(depth: 0) }
        #expect(quotes.count == 1)
    }

    @Test("Blockquote delimiter is the > prefix")
    func blockquoteDelimiter() {
        let spans = SyntaxHighlighter.parse("> hello")
        let quotes = spans.filter { $0.kind == .blockquote(depth: 0) }
        #expect(quotes.count == 1)
        #expect(quotes[0].delimiterRanges.count >= 1)
        // Content should be "hello"
        #expect(quotes[0].contentRange.length == 5)
    }

    @Test("Bold inside blockquote is detected")
    func boldInsideBlockquote() {
        let spans = SyntaxHighlighter.parse("> **bold**")
        let quotes = spans.filter { $0.kind == .blockquote(depth: 0) }
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

    @Test("Unchecked todo whose body contains [x] stays unchecked")
    func uncheckedTodoWithBracketXInBody() {
        // swift-markdown reports this item's checkbox as `.checked` because it
        // scans the whole line for `[x]`; the state must come from the leading
        // `[ ]` marker instead. (Regression: such items rendered struck-through.)
        for line in ["- [ ] body with [x] later",
                     "- [ ] body with `[x]` in code",
                     "- [ ] mentions `- [x]` syntax"] {
            let spans = SyntaxHighlighter.parse(line)
            let items = spans.filter { if case .listItem = $0.kind { return true }; return false }
            #expect(items.count == 1)
            if case .listItem(_, let checkbox) = items.first?.kind {
                #expect(checkbox == .unchecked, "expected unchecked for \(line.debugDescription)")
            } else {
                #expect(Bool(false), "Expected listItem for \(line.debugDescription)")
            }
        }
    }

    @Test("Indented list item (2 spaces) produces a listItem span")
    func indentedTwoSpaces() {
        let spans = SyntaxHighlighter.parse("  - hello")
        let items = spans.filter { if case .listItem = $0.kind { return true }; return false }
        #expect(items.count == 1)
    }

    @Test("Indented list item (4 spaces) produces a listItem span")
    func indentedFourSpaces() {
        let spans = SyntaxHighlighter.parse("    - hello")
        let items = spans.filter { if case .listItem = $0.kind { return true }; return false }
        #expect(items.count == 1)
        // Should NOT also produce a codeBlock span
        let codeBlocks = spans.filter { if case .codeBlock = $0.kind { return true }; return false }
        #expect(codeBlocks.count == 0)
    }

    @Test("Indented list item (8 spaces) produces a listItem span")
    func indentedEightSpaces() {
        let spans = SyntaxHighlighter.parse("        - hello")
        let items = spans.filter { if case .listItem = $0.kind { return true }; return false }
        #expect(items.count == 1)
    }

    @Test("Indented list item preserves inline formatting")
    func indentedListInlineFormatting() {
        let spans = SyntaxHighlighter.parse("    - *italic* and **bold**")
        let items = spans.filter { if case .listItem = $0.kind { return true }; return false }
        #expect(items.count == 1)
        let italics = spans.filter { $0.kind == .italic }
        #expect(italics.count == 1)
        let bolds = spans.filter { $0.kind == .bold }
        #expect(bolds.count == 1)
    }

    @Test("Indented unchecked todo (4 spaces) detects unchecked checkbox")
    func indentedUncheckedTodo() {
        let spans = SyntaxHighlighter.parse("    - [ ] deep todo")
        let items = spans.filter { if case .listItem = $0.kind { return true }; return false }
        #expect(items.count == 1)
        if case .listItem(_, let checkbox) = items[0].kind {
            #expect(checkbox == .unchecked)
        } else {
            #expect(Bool(false), "Expected listItem")
        }
    }

    @Test("Indented checked todo (4 spaces) detects checked checkbox")
    func indentedCheckedTodo() {
        let spans = SyntaxHighlighter.parse("    - [x] deep done")
        let items = spans.filter { if case .listItem = $0.kind { return true }; return false }
        #expect(items.count == 1)
        if case .listItem(_, let checkbox) = items[0].kind {
            #expect(checkbox == .checked)
        } else {
            #expect(Bool(false), "Expected listItem")
        }
    }

    @Test("Deeply indented todo (8 spaces) detects checkbox")
    func deeplyIndentedTodo() {
        let spans = SyntaxHighlighter.parse("        - [ ] level 4 todo")
        let items = spans.filter { if case .listItem = $0.kind { return true }; return false }
        #expect(items.count == 1)
        if case .listItem(_, let checkbox) = items[0].kind {
            #expect(checkbox == .unchecked)
        } else {
            #expect(Bool(false), "Expected listItem")
        }
    }

    @Test("Indented ordered item (4 spaces) produces an ordered listItem span")
    func indentedOrderedFourSpaces() {
        let spans = SyntaxHighlighter.parse("    1. hello")
        let items = spans.filter { if case .listItem = $0.kind { return true }; return false }
        #expect(items.count == 1)
        if case .listItem(let ordered, _) = items[0].kind {
            #expect(ordered == true)
        } else {
            #expect(Bool(false), "Expected listItem")
        }
        // Should NOT also produce a codeBlock span.
        let codeBlocks = spans.filter { if case .codeBlock = $0.kind { return true }; return false }
        #expect(codeBlocks.count == 0)
    }

    @Test("Deeply indented ordered item (8 spaces, paren) is ordered")
    func deeplyIndentedOrderedParen() {
        let spans = SyntaxHighlighter.parse("        2) deep")
        let items = spans.filter { if case .listItem = $0.kind { return true }; return false }
        #expect(items.count == 1)
        if case .listItem(let ordered, _) = items[0].kind {
            #expect(ordered == true)
        } else {
            #expect(Bool(false), "Expected listItem")
        }
    }

    @Test("Tab-indented ordered item is ordered")
    func tabIndentedOrdered() {
        let spans = SyntaxHighlighter.parse("\t1. tabbed")
        let items = spans.filter { if case .listItem = $0.kind { return true }; return false }
        #expect(items.count == 1)
        if case .listItem(let ordered, _) = items[0].kind {
            #expect(ordered == true)
        } else {
            #expect(Bool(false), "Expected listItem")
        }
    }

    @Test("Indented todo content excludes the checkbox delimiter")
    func indentedTodoContentRange() {
        let text = "    - [ ] task"
        let spans = SyntaxHighlighter.parse(text)
        let items = spans.filter { if case .listItem = $0.kind { return true }; return false }
        #expect(items.count == 1)
        // Content should be "task" — the "    - [ ] " prefix is the delimiter.
        let content = (text as NSString).substring(with: items[0].contentRange)
        #expect(content == "task")
    }

    @Test("Indented todo with uppercase [X] is checked")
    func indentedUppercaseChecked() {
        let spans = SyntaxHighlighter.parse("    - [X] done")
        let items = spans.filter { if case .listItem = $0.kind { return true }; return false }
        if case .listItem(_, let checkbox) = items[0].kind {
            #expect(checkbox == .checked)
        } else {
            #expect(Bool(false), "Expected listItem")
        }
    }
}

// MARK: - Tables

@Suite("SyntaxHighlighter — Tables")
struct TableTests {

    @Test("Table produces a table span")
    func basicTable() {
        let text = "| A | B |\n| --- | --- |\n| 1 | 2 |"
        let spans = SyntaxHighlighter.parse(text)
        let tables = spans.filter { $0.kind == .table }
        #expect(tables.count == 1)
    }

    @Test("Table full range covers entire table text")
    func tableFullRange() {
        let text = "| A | B |\n| --- | --- |\n| 1 | 2 |"
        let spans = SyntaxHighlighter.parse(text)
        let tables = spans.filter { $0.kind == .table }
        #expect(tables.count == 1)
        #expect(tables[0].fullRange == NSRange(location: 0, length: (text as NSString).length))
    }

    @Test("Table with single column")
    func singleColumn() {
        let text = "| H |\n| --- |\n| V |"
        let spans = SyntaxHighlighter.parse(text)
        let tables = spans.filter { $0.kind == .table }
        #expect(tables.count == 1)
    }

    @Test("Table delimiter ranges capture separator row")
    func tableSeparatorInDelimiters() {
        let text = "| A |\n| --- |\n| 1 |"
        let spans = SyntaxHighlighter.parse(text)
        let tables = spans.filter { $0.kind == .table }
        #expect(tables.count == 1)
        // There should be delimiter ranges between head and body (the separator)
        #expect(!tables[0].delimiterRanges.isEmpty)
    }
}

// MARK: - Code Blocks

@Suite("SyntaxHighlighter — Code Blocks")
struct CodeBlockTests {

    @Test("Fenced code block with backticks produces codeBlock span")
    func backtickFence() {
        let text = "```\nhello\n```"
        let spans = SyntaxHighlighter.parse(text)
        let codeBlocks = spans.filter {
            if case .codeBlock = $0.kind { return true }
            return false
        }
        #expect(codeBlocks.count == 1)
    }

    @Test("Fenced code block with language annotation")
    func languageAnnotation() {
        let text = "```swift\nlet x = 1\n```"
        let spans = SyntaxHighlighter.parse(text)
        let codeBlocks = spans.filter {
            if case .codeBlock = $0.kind { return true }
            return false
        }
        #expect(codeBlocks.count == 1)
        if case .codeBlock(let lang) = codeBlocks[0].kind {
            #expect(lang == "swift")
        }
    }

    @Test("Code block content range excludes fence lines")
    func contentExcludesFences() {
        let text = "```\nhello\n```"
        let spans = SyntaxHighlighter.parse(text)
        let codeBlocks = spans.filter {
            if case .codeBlock = $0.kind { return true }
            return false
        }
        #expect(codeBlocks.count == 1)
        let content = (text as NSString).substring(with: codeBlocks[0].contentRange)
        #expect(content == "hello")
    }

    @Test("Indented code block: no delimiters, all content")
    func indentedCode() {
        let text = "    let x = 1\n    let y = 2"
        let spans = SyntaxHighlighter.parse(text)
        let codeBlocks = spans.filter {
            if case .codeBlock = $0.kind { return true }
            return false
        }
        #expect(codeBlocks.count == 1)
        guard let span = codeBlocks.first else { return }
        if case .codeBlock(let lang) = span.kind { #expect(lang == nil) }
        #expect(span.contentRange == span.fullRange)
        #expect(span.delimiterRanges.isEmpty)
        // The first line's leading indent is inside the span (swift-markdown's
        // node range starts after it; the walker expands back to line start).
        #expect(span.fullRange.location == 0)
    }

    @Test("Code block with tilde fences")
    func tildeFence() {
        let text = "~~~\ncode\n~~~"
        let spans = SyntaxHighlighter.parse(text)
        let codeBlocks = spans.filter {
            if case .codeBlock = $0.kind { return true }
            return false
        }
        #expect(codeBlocks.count == 1)
    }

    @Test("Code block with multiple lines of content")
    func multipleLines() {
        let text = "```\nline1\nline2\nline3\n```"
        let spans = SyntaxHighlighter.parse(text)
        let codeBlocks = spans.filter {
            if case .codeBlock = $0.kind { return true }
            return false
        }
        #expect(codeBlocks.count == 1)
        let content = (text as NSString).substring(with: codeBlocks[0].contentRange)
        #expect(content.contains("line1"))
        #expect(content.contains("line2"))
        #expect(content.contains("line3"))
    }

    @Test("Code block delimiter ranges cover fence lines")
    func delimiterRanges() {
        let text = "```\nhello\n```"
        let spans = SyntaxHighlighter.parse(text)
        let codeBlocks = spans.filter {
            if case .codeBlock = $0.kind { return true }
            return false
        }
        #expect(codeBlocks.count == 1)
        #expect(codeBlocks[0].delimiterRanges.count == 2)
        // Opening: "```\n"
        let openDelim = (text as NSString).substring(with: codeBlocks[0].delimiterRanges[0])
        #expect(openDelim == "```\n")
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
        if case .image(let dest, _, _) = images[0].kind {
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

// MARK: - Inline Math

@Suite("SyntaxHighlighter — Inline Math")
struct InlineMathTests {

    private func mathSpans(_ text: String) -> [SyntaxHighlighter.Span] {
        SyntaxHighlighter.parse(text).filter {
            if case .math = $0.kind { return true }; return false
        }
    }

    @Test("$x$ produces an inline math span with correct ranges")
    func basicInline() {
        let spans = mathSpans("$x$")
        #expect(spans.count == 1)
        let s = spans[0]
        #expect(s.kind == .math(display: false))
        #expect(s.fullRange == NSRange(location: 0, length: 3))
        #expect(s.contentRange == NSRange(location: 1, length: 1))
        #expect(s.delimiterRanges == [NSRange(location: 0, length: 1),
                                      NSRange(location: 2, length: 1)])
    }

    @Test("Math in the middle of text has the right offset")
    func mathInMiddle() {
        let spans = mathSpans("energy $E=mc^2$ here")
        #expect(spans.count == 1)
        #expect(spans[0].fullRange == NSRange(location: 7, length: 8))
        #expect(spans[0].contentRange == NSRange(location: 8, length: 6))
    }

    @Test("Prose dollar amounts are not matched")
    func proseDollarsIgnored() {
        #expect(mathSpans("it cost $5 to $10 today").isEmpty)
    }

    @Test("Escaped \\$ is not a delimiter")
    func escapedDollar() {
        #expect(mathSpans("price is \\$5 each").isEmpty)
    }

    @Test("$ inside inline code is not matched")
    func dollarsInCode() {
        let spans = mathSpans("`$x$`")
        #expect(spans.isEmpty)
    }

    @Test("$$x$$ on one line is display math, not inline")
    func singleLineDisplay() {
        let spans = mathSpans("$$x$$")
        #expect(spans.count == 1)
        #expect(spans[0].kind == .math(display: true))
        #expect(spans[0].contentRange == NSRange(location: 2, length: 1))
    }

    @Test("Opening $ followed by space is not math")
    func openFollowedBySpace() {
        #expect(mathSpans("a $ b $ c").isEmpty)
    }
}

// MARK: - Display Math

@Suite("SyntaxHighlighter — Display Math")
struct DisplayMathTests {

    private func mathSpans(_ text: String) -> [SyntaxHighlighter.Span] {
        SyntaxHighlighter.parse(text).filter {
            if case .math = $0.kind { return true }; return false
        }
    }

    @Test("Multi-line $$…$$ block produces a display-math span")
    func multiLineDisplay() {
        let text = "$$\nx = y\n$$"
        let spans = mathSpans(text)
        #expect(spans.count == 1)
        #expect(spans[0].kind == .math(display: true))
        // full range spans the opening $$ through the closing $$.
        #expect(spans[0].fullRange == NSRange(location: 0, length: (text as NSString).length))
        // content is the text between the delimiters (newlines included).
        let content = (text as NSString).substring(with: spans[0].contentRange)
        #expect(content == "\nx = y\n")
    }

    @Test("Display delimiters are the two $$")
    func displayDelimiters() {
        let spans = mathSpans("$$a$$")
        #expect(spans.count == 1)
        #expect(spans[0].delimiterRanges == [NSRange(location: 0, length: 2),
                                             NSRange(location: 3, length: 2)])
    }

    @Test("A normal paragraph is not display math")
    func paragraphNotDisplay() {
        #expect(mathSpans("just a paragraph").isEmpty)
    }

    @Test("Inline $$…$$ sharing a line with prose is display math")
    func inlineDisplayInProse() {
        let text = "text $$x$$ more"
        let spans = mathSpans(text)
        #expect(spans.count == 1)
        #expect(spans[0].kind == .math(display: true))
        #expect(spans[0].fullRange == NSRange(location: 5, length: 5))
        #expect((text as NSString).substring(with: spans[0].contentRange) == "x")
    }

    @Test("Two $$…$$ runs on one line produce two display spans")
    func twoRunsOneLine() {
        let spans = mathSpans("$$a$$ and $$b$$")
        #expect(spans.count == 2)
        #expect(spans.allSatisfy { $0.kind == .math(display: true) })
    }

    @Test("$$ with space after the delimiter is not display math")
    func spaceAfterDelimiterNotDisplay() {
        #expect(mathSpans("a $$ x $$ b").isEmpty)
    }

    @Test("Loose $$ in prose (close preceded by space) is not display math")
    func looseProseDollarsNotDisplay() {
        #expect(mathSpans("cost $$5 for $$10 today").isEmpty)
    }

    // #325: a `$$` block indented under a list item. The closing `$$` is
    // preceded by indentation, which must not count as a "loose" delimiter.
    @Test("Indented $$…$$ block (list continuation) is display math")
    func indentedBlockIsDisplay() {
        let text = "  $$\nx = y\n  $$"
        let spans = mathSpans(text)
        #expect(spans.count == 1)
        #expect(spans[0].kind == .math(display: true))
        #expect(spans[0].fullRange == NSRange(location: 2, length: (text as NSString).length - 2))
        #expect((text as NSString).substring(with: spans[0].contentRange) == "\nx = y\n  ")
    }
}

// MARK: - Autolinks (GFM extension)

@Suite("SyntaxHighlighter — Autolinks")
struct AutolinkTests {

    private func links(_ text: String) -> [(text: String, dest: String)] {
        SyntaxHighlighter.parse(text).compactMap { s in
            guard case .link(let d) = s.kind else { return nil }
            return ((text as NSString).substring(with: s.contentRange), d)
        }
    }

    @Test("Bare www autolink gets an http:// destination")
    func www() {
        let l = links("visit www.example.com now")
        #expect(l.count == 1)
        #expect(l[0].text == "www.example.com")
        #expect(l[0].dest == "http://www.example.com")
    }

    @Test("Scheme autolink keeps its own destination")
    func scheme() {
        let l = links("see https://example.com/page?x=1 there")
        #expect(l.map(\.dest) == ["https://example.com/page?x=1"])
    }

    @Test("Trailing punctuation is trimmed")
    func trailingPunct() {
        #expect(links("go to www.example.com.").map(\.text) == ["www.example.com"])
        #expect(links("really, www.example.com!").map(\.text) == ["www.example.com"])
    }

    @Test("Unbalanced trailing paren is trimmed; balanced is kept")
    func parens() {
        #expect(links("(see www.example.com)").map(\.text) == ["www.example.com"])
        #expect(links("https://en.wikipedia.org/wiki/Markdown_(language)").map(\.text)
                == ["https://en.wikipedia.org/wiki/Markdown_(language)"])
    }

    @Test("Trailing &entity; is trimmed")
    func entity() {
        #expect(links("www.example.com/foo&amp;").map(\.text) == ["www.example.com/foo"])
    }

    @Test("Email autolink gets a mailto destination")
    func email() {
        let l = links("mail foo.bar+baz@sub.example.com please")
        #expect(l.map(\.dest) == ["mailto:foo.bar+baz@sub.example.com"])
    }

    @Test("Invalid domains don't autolink")
    func invalidDomain() {
        #expect(links("http://nodot").isEmpty)
        #expect(links("www.ex_ample.com").isEmpty)   // _ in the last two labels
        #expect(links("it cost $5 www").isEmpty)
    }

    @Test("A URL mid-word doesn't autolink")
    func midWord() {
        #expect(links("xhttp://example.com").isEmpty)
    }

    @Test("No autolink inside code spans")
    func insideCode() {
        #expect(links("`www.example.com`").isEmpty)
    }

    @Test("No autolink inside a real markdown link; a bare one next to it still links")
    func besideRealLink() {
        let l = links("[x](http://a.com) http://b.com")
        // The [x](…) link comes from the walker; the autolink pass adds b only.
        let autos = l.filter { $0.dest == "http://b.com" }
        #expect(autos.count == 1)
        #expect(!l.contains { $0.text.contains("a.com") && $0.dest == "http://a.com" && $0.text == "http://a.com" })
    }

    @Test("No autolink inside an <img> src attribute")
    func insideImgTag() {
        let spans = SyntaxHighlighter.parse("<img src=\"http://example.com/x.png\">")
        let autos = spans.filter {
            if case .link = $0.kind { return true }; return false
        }
        #expect(autos.isEmpty)
    }
}
