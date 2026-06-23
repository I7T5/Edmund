import Testing
import AppKit
@testable import EdmundCore

// Tests for the Format-menu commands (EditorTextView+Formatting*). Each asserts
// on `rawSource` and the resulting selection, and — for toggles — that applying
// twice restores the original (invertibility), per the spec.

@MainActor
private func mk(_ content: String, _ sel: NSRange) -> EditorTextView {
    let e = makeEditor()
    e.loadContent(content)
    e.setSelectedRange(sel)
    return e
}

// MARK: - Inline font styles

@MainActor @Suite struct FormatInlineWrapTests {

    @Test func boldWrapsSelection() {
        let e = mk("hello world", NSRange(location: 6, length: 5))
        e.formatBold(nil)
        #expect(e.rawSource == "hello **world**")
        #expect(e.selectedRange() == NSRange(location: 8, length: 5))  // "world" still selected
    }

    @Test func boldIsInvertibleOnSelection() {
        let e = mk("hello world", NSRange(location: 6, length: 5))
        e.formatBold(nil)
        e.formatBold(nil)
        #expect(e.rawSource == "hello world")
        #expect(e.selectedRange() == NSRange(location: 6, length: 5))
    }

    @Test func boldEmptyInsertAndRemoveAtCaret() {
        let e = mk("ab", NSRange(location: 1, length: 0))
        e.formatBold(nil)
        #expect(e.rawSource == "a****b")
        #expect(e.selectedRange() == NSRange(location: 3, length: 0))  // caret between **|**
        e.formatBold(nil)
        #expect(e.rawSource == "ab")
        #expect(e.selectedRange() == NSRange(location: 1, length: 0))
    }

    @Test func boldUnwrapsCurrentWordAtCaret() {
        let e = mk("**bold**", NSRange(location: 3, length: 0))  // caret inside "bold"
        e.formatBold(nil)
        #expect(e.rawSource == "bold")
        #expect(e.selectedRange() == NSRange(location: 1, length: 0))
    }

    @Test func italicUnderlineStrikeHighlightCodeMath() {
        func wrap(_ open: String, _ close: String, _ action: (EditorTextView) -> Void) -> String {
            let e = mk("x", NSRange(location: 0, length: 1))
            action(e)
            return e.rawSource
        }
        #expect(wrap("*", "*") { $0.formatItalic(nil) } == "*x*")
        #expect(wrap("<u>", "</u>") { $0.formatUnderline(nil) } == "<u>x</u>")
        #expect(wrap("~~", "~~") { $0.formatStrikethrough(nil) } == "~~x~~")
        #expect(wrap("==", "==") { $0.formatHighlight(nil) } == "==x==")
        #expect(wrap("`", "`") { $0.formatCode(nil) } == "`x`")
        #expect(wrap("$", "$") { $0.formatInlineMath(nil) } == "$x$")
        #expect(wrap("<kbd>", "</kbd>") { $0.formatKeyboard(nil) } == "<kbd>x</kbd>")
        #expect(wrap("%%", "%%") { $0.formatComment(nil) } == "%%x%%")
    }

    @Test func emptyInlineCaretCentersForMultiCharDelimiter() {
        let e = mk("", NSRange(location: 0, length: 0))
        e.formatKeyboard(nil)
        #expect(e.rawSource == "<kbd></kbd>")
        #expect(e.selectedRange() == NSRange(location: 5, length: 0))  // between <kbd>|</kbd>
    }

    @Test func mathBlockWrapsSelection() {
        let e = mk("E=mc^2", NSRange(location: 0, length: 6))
        e.formatMathBlock(nil)
        #expect(e.rawSource == "$$E=mc^2$$")
    }
}

// MARK: - Wikilink / link / image

@MainActor @Suite struct FormatLinkTests {

    @Test func wikilinkWrapsAndInverts() {
        let e = mk("Page", NSRange(location: 0, length: 4))
        e.formatWikilink(nil)
        #expect(e.rawSource == "[[Page]]")
        e.formatWikilink(nil)
        #expect(e.rawSource == "Page")
    }

    @Test func wikilinkEmptyCaret() {
        let e = mk("", NSRange(location: 0, length: 0))
        e.formatWikilink(nil)
        #expect(e.rawSource == "[[]]")
        #expect(e.selectedRange() == NSRange(location: 2, length: 0))
    }

    @Test func linkWrapsSelectionCaretInParens() {
        let e = mk("Anthropic", NSRange(location: 0, length: 9))
        e.formatLink(nil)
        #expect(e.rawSource == "[Anthropic]()")
        #expect(e.selectedRange() == NSRange(location: 12, length: 0))  // inside ( | )
    }

    @Test func linkEmptyCaretInParens() {
        let e = mk("", NSRange(location: 0, length: 0))
        e.formatLink(nil)
        #expect(e.rawSource == "[]()")
        #expect(e.selectedRange() == NSRange(location: 3, length: 0))
    }

    @Test func linkUnwrapsWhenSelectionIsALink() {
        let e = mk("[text](url)", NSRange(location: 0, length: 11))
        e.formatLink(nil)
        #expect(e.rawSource == "text")
    }

    @Test func imageWrapsSelectionCaretInParens() {
        let e = mk("alt", NSRange(location: 0, length: 3))
        e.formatImage(nil)
        #expect(e.rawSource == "![alt]()")
        #expect(e.selectedRange() == NSRange(location: 7, length: 0))  // inside ( | )
    }

    @Test func imageEmptyCaretInParens() {
        let e = mk("", NSRange(location: 0, length: 0))
        e.formatImage(nil)
        #expect(e.rawSource == "![]()")
        #expect(e.selectedRange() == NSRange(location: 4, length: 0))
    }
}

// MARK: - Footnote (not invertible)

@MainActor @Suite struct FormatFootnoteTests {

    @Test func footnoteInsertsMarkerAndDefinition() {
        let e = mk("word", NSRange(location: 4, length: 0))
        e.formatFootnote(nil)
        #expect(e.rawSource == "word[^1]\n[^1]: ")
        #expect(e.selectedRange() == NSRange(location: e.rawSource.utf16.count, length: 0))
    }

    @Test func footnoteNumbersIncrementByExistingMax() {
        let e = mk("a[^1] b\n[^1]: first", NSRange(location: 7, length: 0))
        e.formatFootnote(nil)
        #expect(e.rawSource.contains("b[^2]"))
        #expect(e.rawSource.hasSuffix("[^2]: "))
    }
}

// MARK: - Block prefixes (lists, quote, heading, checklist)

@MainActor @Suite struct FormatBlockPrefixTests {

    @Test func bulletedListAndInverse() {
        let e = mk("a\nb", NSRange(location: 0, length: 3))
        e.formatBulletedList(nil)
        #expect(e.rawSource == "- a\n- b")
        e.formatBulletedList(nil)
        #expect(e.rawSource == "a\nb")
    }

    @Test func numberedListSequential() {
        let e = mk("a\nb\nc", NSRange(location: 0, length: 5))
        e.formatNumberedList(nil)
        #expect(e.rawSource == "1. a\n2. b\n3. c")
        e.formatNumberedList(nil)
        #expect(e.rawSource == "a\nb\nc")
    }

    @Test func numberedListContinuesFromPrecedingNumber() {
        // Select only the "a" and "b" lines; the line before is "1. x".
        let e = mk("1. x\na\nb", NSRange(location: 5, length: 3))
        e.formatNumberedList(nil)
        #expect(e.rawSource == "1. x\n2. a\n3. b")
    }

    @Test func blockQuoteAndInverse() {
        let e = mk("a\nb", NSRange(location: 0, length: 3))
        e.formatBlockQuote(nil)
        #expect(e.rawSource == "> a\n> b")
        e.formatBlockQuote(nil)
        #expect(e.rawSource == "a\nb")
    }

    @Test func headingApplyReplaceAndClear() {
        let e = mk("Title", NSRange(location: 0, length: 0))
        e.applyHeadingLevel(2)
        #expect(e.rawSource == "## Title")
        e.applyHeadingLevel(3)            // replaces #s, not stacks
        #expect(e.rawSource == "### Title")
        e.applyHeadingLevel(3)            // same level clears
        #expect(e.rawSource == "Title")
    }

    @Test func checklistAddsThenTogglesMark() {
        let e = mk("task", NSRange(location: 0, length: 0))
        e.formatChecklist(nil)
        #expect(e.rawSource == "- [ ] task")
        e.formatChecklist(nil)
        #expect(e.rawSource == "- [x] task")
        e.formatChecklist(nil)
        #expect(e.rawSource == "- [ ] task")  // toggles, never back to plain
    }
}

// MARK: - Code block / math block / table / callout

@MainActor @Suite struct FormatBlockInsertTests {

    @Test func codeBlockWrapsAndInverts() {
        let e = mk("let x = 1", NSRange(location: 0, length: 9))
        e.formatCodeBlock(nil)
        #expect(e.rawSource == "```\nlet x = 1\n```")
        #expect(e.selectedRange() == NSRange(location: 3, length: 0))  // caret on info line
        // Re-select the whole fence and toggle off.
        e.setSelectedRange(NSRange(location: 0, length: (e.rawSource as NSString).length))
        e.formatCodeBlock(nil)
        #expect(e.rawSource == "let x = 1")
    }

    @Test func tableInsertsPlaceholderGrid() {
        let e = mk("intro", NSRange(location: 5, length: 0))
        e.formatTable(nil)
        #expect(e.rawSource == "intro\n| Header 1 | Header 2 |\n| --- | --- |\n| Cell 1 | Cell 2 |\n")
        #expect(e.blocks.contains { $0.kind == .table })
    }

    @Test func githubCalloutWrapsUppercase() {
        let e = mk("line1\nline2", NSRange(location: 0, length: 11))
        e.applyCalloutType("NOTE")
        #expect(e.rawSource == "> [!NOTE]\n> line1\n> line2")
        e.setSelectedRange(NSRange(location: 0, length: (e.rawSource as NSString).length))
        e.applyCalloutType("NOTE")
        #expect(e.rawSource == "line1\nline2")
    }

    @Test func obsidianCalloutWrapsLowercase() {
        let e = mk("body", NSRange(location: 0, length: 4))
        e.applyCalloutType("abstract")
        #expect(e.rawSource == "> [!abstract]\n> body")
    }
}

// MARK: - Storage integrity (oracle)

@MainActor @Suite struct FormattingOracleTests {

    @Test func storageMatchesAfterWrap() {
        let e = mk("alpha beta gamma", NSRange(location: 6, length: 4))
        e.formatBold(nil)
        drainAllStyling(e)
        assertMatchesFullRecomposeOracle(e)
    }

    @Test func storageMatchesAfterMultilineList() {
        let e = mk("one\ntwo\nthree", NSRange(location: 0, length: 13))
        e.formatBulletedList(nil)
        drainAllStyling(e)
        assertMatchesFullRecomposeOracle(e)
    }

    @Test func storageMatchesAfterCallout() {
        let e = mk("a\nb", NSRange(location: 0, length: 3))
        e.applyCalloutType("NOTE")
        drainAllStyling(e)
        assertMatchesFullRecomposeOracle(e)
    }
}
