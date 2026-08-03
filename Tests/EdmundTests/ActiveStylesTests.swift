import Testing
import AppKit
@testable import EdmundCore

// What the format popup reads to decide which rows show as already-applied.

@MainActor
private func mk(_ content: String, _ caret: Int) -> EditorTextView {
    let e = makeEditor()
    e.loadContent(content)
    e.setSelectedRange(NSRange(location: caret, length: 0))
    return e
}

@MainActor @Suite struct ActiveInlineStyleTests {

    @Test func detectsBoldInsideDelimiters() {
        #expect(mk("a **word** b", 6).activeInlineStyles().contains(.bold))
    }

    @Test func plainTextHasNoStyles() {
        #expect(mk("a word b", 3).activeInlineStyles().isEmpty)
    }

    /// Typing at either edge of a run continues it, so the button must agree.
    @Test func detectsBoldAtBothEdgesOfTheContent() {
        #expect(mk("a **word** b", 4).activeInlineStyles().contains(.bold))   // before "w"
        #expect(mk("a **word** b", 8).activeInlineStyles().contains(.bold))   // after "d"
    }

    @Test func doesNotLeakOutsideTheRun() {
        #expect(!mk("a **word** b", 0).activeInlineStyles().contains(.bold))
        #expect(!mk("a **word** b", 12).activeInlineStyles().contains(.bold))
    }

    @Test func boldItalicReportsBoth() {
        let s = mk("***word***", 5).activeInlineStyles()
        #expect(s.contains(.bold))
        #expect(s.contains(.italic))
    }

    @Test func detectsItalicStrikethroughHighlightAndCode() {
        #expect(mk("*w* x", 1).activeInlineStyles().contains(.italic))
        #expect(mk("~~w~~ x", 2).activeInlineStyles().contains(.strikethrough))
        #expect(mk("==w== x", 2).activeInlineStyles().contains(.highlight))
        #expect(mk("`w` x", 1).activeInlineStyles().contains(.code))
    }

    @Test func detectsInlineMathButNotDisplayMath() {
        #expect(mk("$x^2$ t", 1).activeInlineStyles().contains(.math))
        #expect(!mk("$$\nx^2\n$$", 3).activeInlineStyles().contains(.math))
    }

    @Test func detectsHTMLFormatTags() {
        #expect(mk("<u>w</u>", 4).activeInlineStyles().contains(.underline))
        #expect(mk("H<sub>2</sub>O", 6).activeInlineStyles().contains(.subscript))
        #expect(mk("x<sup>2</sup>", 6).activeInlineStyles().contains(.superscript))
    }

    /// The popup's own commands must round-trip: apply, then detect.
    @Test func detectsWhatTheCommandsJustInserted() {
        let e = mk("word", 0)
        e.setSelectedRange(NSRange(location: 0, length: 4))
        e.formatBold(nil)
        e.setSelectedRange(NSRange(location: 3, length: 0))   // inside "**wo|rd**"
        #expect(e.activeInlineStyles().contains(.bold))
    }

    @Test func detectsStylesOnLaterBlocks() {
        // Offsets are block-relative internally; a second block must still work.
        #expect(mk("first\n\nsecond **bold** here", 17).activeInlineStyles().contains(.bold))
    }
}

@MainActor @Suite struct ActiveBlockStyleTests {

    @Test func plainParagraphIsBody() {
        #expect(mk("just text", 4).activeBlockStyle() == .body)
    }

    @Test func detectsHeadingLevels() {
        #expect(mk("# One", 3).activeBlockStyle() == .heading(level: 1))
        #expect(mk("## Two", 4).activeBlockStyle() == .heading(level: 2))
        #expect(mk("### Three", 5).activeBlockStyle() == .heading(level: 3))
    }

    @Test func distinguishesTheThreeListFlavours() {
        #expect(mk("- item", 3).activeBlockStyle() == .bulletedList)
        #expect(mk("1. item", 4).activeBlockStyle() == .numberedList)
        #expect(mk("- [ ] task", 8).activeBlockStyle() == .checklist)
    }

    @Test func distinguishesQuoteFromCallout() {
        #expect(mk("> quoted", 4).activeBlockStyle() == .blockQuote)
        #expect(mk("> [!NOTE]\n> body", 13).activeBlockStyle() == .callout)
    }

    @Test func detectsCodeAndMathBlocks() {
        #expect(mk("```\ncode\n```", 5).activeBlockStyle() == .codeBlock)
        #expect(mk("$$\nx^2\n$$", 4).activeBlockStyle() == .mathBlock)
    }

    /// A block may mix list markers line by line, so the caret's own line wins.
    @Test func usesTheCaretsOwnLineInAMixedList() {
        let content = "- bullet\n- [ ] task"
        #expect(mk(content, 4).activeBlockStyle() == .bulletedList)
        #expect(mk(content, 16).activeBlockStyle() == .checklist)
    }
}
