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

    @Test func boldWrapsWordAtCaret() {
        // Caret inside a plain word wraps the whole word; caret keeps its spot.
        let e = mk("anything", NSRange(location: 4, length: 0))  // "anyt|hing"
        e.formatBold(nil)
        #expect(e.rawSource == "**anything**")
        #expect(e.selectedRange() == NSRange(location: 6, length: 0))  // "**anyt|hing**"
        // Pressing again unwraps.
        e.formatBold(nil)
        #expect(e.rawSource == "anything")
        #expect(e.selectedRange() == NSRange(location: 4, length: 0))
    }

    @Test func boldEmptyInsertAndRemoveWhenNoWord() {
        // Caret not adjacent to a word → insert empty delimiters, caret centred.
        let e = mk("()", NSRange(location: 1, length: 0))
        e.formatBold(nil)
        #expect(e.rawSource == "(****)")
        #expect(e.selectedRange() == NSRange(location: 3, length: 0))  // (**|**)
        e.formatBold(nil)
        #expect(e.rawSource == "()")
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

    @Test func mathBlockWrapsSelectionAsBlock() {
        let e = mk("E=mc^2", NSRange(location: 0, length: 6))
        e.formatMathBlock(nil)
        #expect(e.rawSource == "$$\nE=mc^2\n$$")
        #expect(e.selectedRange() == NSRange(location: 3, length: 0))  // caret on content line
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

    @Test func tableInserts3x2WithPaddedDividers() {
        let e = mk("", NSRange(location: 0, length: 0))
        e.formatTable(nil)
        let lines = e.rawSource.components(separatedBy: "\n")
        #expect(lines[0] == "| Header 1 | Header 2 | Header 3 |")
        #expect(lines[1] == "| -------- | -------- | -------- |")
        #expect(lines[2] == "| Cell 1 | Cell 2 | Cell 3 |")
        #expect(lines[3] == "| Cell 4 | Cell 5 | Cell 6 |")
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

// MARK: - Whitespace stripping for inline wraps

@MainActor @Suite struct FormatWhitespaceTests {

    @Test func boldSkipsLeadingSpace() {
        // Selection " world" — the leading space should stay outside the markers.
        let e = mk("hello world", NSRange(location: 5, length: 6))
        e.formatBold(nil)
        #expect(e.rawSource == "hello **world**")
    }

    @Test func boldSkipsTrailingSpace() {
        let e = mk("hello world", NSRange(location: 0, length: 6))  // "hello "
        e.formatBold(nil)
        #expect(e.rawSource == "**hello** world")
    }

    @Test func boldSkipsBothSides() {
        let e = mk("a word b", NSRange(location: 1, length: 6))  // " word "
        e.formatBold(nil)
        #expect(e.rawSource == "a **word** b")
    }

    @Test func boldInvertibleWithLeadingSpace() {
        let e = mk("a **word** b", NSRange(location: 1, length: 9))  // " **word**"
        e.formatBold(nil)
        #expect(e.rawSource == "a word b")
    }
}

// MARK: - List-type replacement

@MainActor @Suite struct FormatListReplacementTests {

    @Test func checklistReplacesBullet() {
        let e = mk("- item", NSRange(location: 0, length: 0))
        e.formatChecklist(nil)
        #expect(e.rawSource == "- [ ] item")
    }

    @Test func checklistReplacesNumbered() {
        let e = mk("1. item", NSRange(location: 0, length: 0))
        e.formatChecklist(nil)
        #expect(e.rawSource == "- [ ] item")
    }

    @Test func bulletReplaceChecklist() {
        let e = mk("- [ ] task", NSRange(location: 0, length: 10))
        e.formatBulletedList(nil)
        #expect(e.rawSource == "- task")
    }

    @Test func bulletReplaceNumbered() {
        let e = mk("1. item", NSRange(location: 0, length: 7))
        e.formatBulletedList(nil)
        #expect(e.rawSource == "- item")
    }

    @Test func numberedReplacesBullet() {
        let e = mk("- item", NSRange(location: 0, length: 6))
        e.formatNumberedList(nil)
        #expect(e.rawSource == "1. item")
    }

    @Test func numberedReplacesChecklist() {
        let e = mk("- [ ] task", NSRange(location: 0, length: 10))
        e.formatNumberedList(nil)
        #expect(e.rawSource == "1. task")
    }

    @Test func bulletToggleOffIgnoresChecklists() {
        // Checklist lines start with "- " so the old toggle-off would have fired.
        // The new code only toggles off when they are *plain* bullets.
        let e = mk("- [ ] task", NSRange(location: 0, length: 10))
        e.formatBulletedList(nil)
        // Should REPLACE (not strip "- " leaving "[ ] task").
        #expect(e.rawSource == "- task")
    }
}

// MARK: - Word expansion for link / wikilink / image

@MainActor @Suite struct FormatWordExpansionTests {

    @Test func wikilinkExpandsToWordAtCaret() {
        let e = mk("hello world", NSRange(location: 7, length: 0))  // caret in "world"
        e.formatWikilink(nil)
        #expect(e.rawSource == "hello [[world]]")
    }

    @Test func linkExpandsToWordAtCaret() {
        let e = mk("anthropic", NSRange(location: 4, length: 0))  // caret mid-word
        e.formatLink(nil)
        #expect(e.rawSource == "[anthropic]()")
        #expect(e.selectedRange() == NSRange(location: 12, length: 0))  // inside ()
    }

    @Test func imageExpandsToWordAtCaret() {
        let e = mk("logo", NSRange(location: 2, length: 0))
        e.formatImage(nil)
        #expect(e.rawSource == "![logo]()")
    }

    @Test func footnoteExpandsToWordEndAtCaret() {
        let e = mk("word", NSRange(location: 2, length: 0))  // caret mid-word
        e.formatFootnote(nil)
        // Marker goes after "word" (the word end), not after the caret position.
        #expect(e.rawSource.hasPrefix("word[^1]"))
    }
}

// MARK: - Link invertibility at caret

@MainActor @Suite struct FormatLinkCaretTests {

    @Test func linkUnwrapsWhenCaretInsideLink() {
        let e = mk("[text](url)", NSRange(location: 4, length: 0))  // caret in "text"
        e.formatLink(nil)
        #expect(e.rawSource == "text")
    }

    @Test func linkUnwrapsWhenCaretInUrl() {
        let e = mk("[text](url)", NSRange(location: 8, length: 0))  // caret in "url"
        e.formatLink(nil)
        #expect(e.rawSource == "text")
    }

    @Test func mathBlockToggleOff() {
        let e = mk("$$\nE=mc^2\n$$", NSRange(location: 0, length: 12))
        e.formatMathBlock(nil)
        #expect(e.rawSource == "E=mc^2")
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

// MARK: - Compound emphasis

@MainActor @Suite struct FormatCompoundEmphasisTests {

    @Test func cmdBThenCmdIProducesTripleStar() {
        let e = mk("word", NSRange(location: 0, length: 4))
        e.formatBold(nil)
        e.formatItalic(nil)
        #expect(e.rawSource == "***word***")
    }

    @Test func cmdIThenCmdBAlsoProducesTripleStar() {
        let e = mk("word", NSRange(location: 0, length: 4))
        e.formatItalic(nil)
        e.formatBold(nil)
        #expect(e.rawSource == "***word***")
    }

    // Selecting the bold span inside ***word*** and pressing Cmd+B peels bold.
    @Test func boldOffFromTripleStarBySelectingBoldSpan() {
        let e = mk("***word***", NSRange(location: 1, length: 8))  // "**word**"
        e.formatBold(nil)
        #expect(e.rawSource == "*word*")
    }

    // Isolation must not block legitimate single-delimiter toggle-off.
    @Test func italicToggleOffStillWorksOnPlainItalic() {
        let e = mk("*word*", NSRange(location: 1, length: 4))
        e.formatItalic(nil)
        #expect(e.rawSource == "word")
    }

    @Test func boldToggleOffStillWorksOnPlainBold() {
        let e = mk("**word**", NSRange(location: 2, length: 4))
        e.formatBold(nil)
        #expect(e.rawSource == "word")
    }

    // Caret compound: bold word + Cmd+I adds italic (markdown star nesting).
    @Test func caretBoldThenItalicCompounds() {
        let e = mk("word", NSRange(location: 2, length: 0))
        e.formatBold(nil)
        #expect(e.rawSource == "**word**")
        e.formatItalic(nil)
        #expect(e.rawSource == "***word***")
    }

    @Test func caretItalicThenBoldCompounds() {
        let e = mk("word", NSRange(location: 2, length: 0))
        e.formatItalic(nil)
        #expect(e.rawSource == "*word*")
        e.formatBold(nil)
        #expect(e.rawSource == "***word***")
    }

    // The exact sequence from the bug video: caret mid-word, B then I then B.
    @Test func caretBIBSequence() {
        let e = mk("anything", NSRange(location: 4, length: 0))
        e.formatBold(nil)
        #expect(e.rawSource == "**anything**")
        e.formatItalic(nil)
        #expect(e.rawSource == "***anything***")
        e.formatBold(nil)        // removes bold, leaving italic
        #expect(e.rawSource == "*anything*")
    }

    // Caret in ***word*** can peel one layer.
    @Test func tripleStarCaretCmdBPeelsBold() {
        let e = mk("***word***", NSRange(location: 5, length: 0))
        e.formatBold(nil)
        #expect(e.rawSource == "*word*")
    }

    @Test func tripleStarCaretCmdIPeelsItalic() {
        let e = mk("***word***", NSRange(location: 5, length: 0))
        e.formatItalic(nil)
        #expect(e.rawSource == "**word**")
    }
}

// MARK: - Thematic break

@MainActor @Suite struct FormatThematicBreakTests {

    @Test func insertsAfterCurrentLine() {
        let e = mk("Hello", NSRange(location: 2, length: 0))
        e.formatThematicBreak(nil)
        // No trailing newline on "Hello" → prepend \n\n to avoid setext heading.
        #expect(e.rawSource == "Hello\n\n---\n")
    }

    @Test func insertsBlankLineSeparatorWhenLineHasNewline() {
        let e = mk("Hello\nWorld", NSRange(location: 2, length: 0))
        e.formatThematicBreak(nil)
        // "Hello\n" ends with newline → insert \n---\n after it, giving a blank before ---.
        #expect(e.rawSource == "Hello\n\n---\nWorld")
    }

    @Test func toggleOffRemovesDashLine() {
        let e = mk("---", NSRange(location: 0, length: 3))
        e.formatThematicBreak(nil)
        #expect(e.rawSource == "")
    }

    @Test func toggleOffWithTrailingNewline() {
        let e = mk("---\n", NSRange(location: 0, length: 3))
        e.formatThematicBreak(nil)
        #expect(e.rawSource == "")
    }

    @Test func caretInsideLineAlsoInserts() {
        // Caret anywhere on the line triggers insert, not toggle-off.
        let e = mk("Line\n", NSRange(location: 2, length: 0))
        e.formatThematicBreak(nil)
        #expect(e.rawSource.contains("---"))
        #expect(e.rawSource.contains("Line"))
    }
}
