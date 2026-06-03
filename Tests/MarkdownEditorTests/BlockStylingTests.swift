import Testing
import AppKit
@testable import MarkdownEditorCore

// ============================================================================
// MARK: - Block Styling: Active Block
// ============================================================================

@Suite("Integration — Block Styling (Active Block)")
struct BlockStylingActiveTests {

    // MARK: - Headings

    @Test("Active # heading has bold font scaled 1.5x")
    @MainActor func activeH1() {
        let editor = makeEditor()
        editor.loadContent("# Title")
        activateBlock(0, in: editor)

        let f = font(at: 2, in: editor)!
        let expectedSize = editor.bodyFont.pointSize * 1.5
        #expect(abs(f.pointSize - expectedSize) < 0.1)
        #expect(NSFontManager.shared.traits(of: f).contains(.boldFontMask))
    }

    @Test("Active ## heading has bold font scaled 1.3x")
    @MainActor func activeH2() {
        let editor = makeEditor()
        editor.loadContent("## Subtitle")
        activateBlock(0, in: editor)

        let f = font(at: 3, in: editor)!
        let expectedSize = editor.bodyFont.pointSize * 1.3
        #expect(abs(f.pointSize - expectedSize) < 0.1)
    }

    @Test("Active ### heading has bold font scaled 1.15x")
    @MainActor func activeH3() {
        let editor = makeEditor()
        editor.loadContent("### Section")
        activateBlock(0, in: editor)

        let f = font(at: 4, in: editor)!
        let expectedSize = editor.bodyFont.pointSize * 1.15
        #expect(abs(f.pointSize - expectedSize) < 0.1)
    }

    @Test("Active heading # prefix is dimmed")
    @MainActor func activeHeadingDimmedPrefix() {
        let editor = makeEditor()
        editor.loadContent("# Title")
        activateBlock(0, in: editor)

        let delimColor = fgColor(at: 0, in: editor)
        #expect(delimColor == NSColor.tertiaryLabelColor)
    }

    // MARK: - Bullet Lists

    @Test("Active - item has list paragraph style")
    @MainActor func activeBulletList() {
        let editor = makeEditor()
        editor.loadContent("- item")
        activateBlock(0, in: editor)

        let a = attrs(at: 0, in: editor)
        let ps = a[.paragraphStyle] as? NSParagraphStyle
        #expect(ps != nil)
        #expect(ps!.headIndent > 0)
    }

    @Test("Active indented list item (4 spaces) has hanging indent")
    @MainActor func activeIndentedBulletList() {
        let editor = makeEditor()
        editor.loadContent("    - item")
        activateBlock(0, in: editor)

        let a = attrs(at: 0, in: editor)
        let ps = a[.paragraphStyle] as? NSParagraphStyle
        #expect(ps != nil)
        #expect(ps!.headIndent > 0)
    }

    @Test("Active - prefix is dimmed")
    @MainActor func activeBulletDimmed() {
        let editor = makeEditor()
        editor.loadContent("- item")
        activateBlock(0, in: editor)

        let delimColor = fgColor(at: 0, in: editor)
        #expect(delimColor == NSColor.tertiaryLabelColor)
    }

    // MARK: - Numbered Lists

    @Test("Active 1. item has list paragraph style")
    @MainActor func activeNumberedList() {
        let editor = makeEditor()
        editor.loadContent("1. item")
        activateBlock(0, in: editor)

        let a = attrs(at: 0, in: editor)
        let ps = a[.paragraphStyle] as? NSParagraphStyle
        #expect(ps != nil)
        #expect(ps!.headIndent > 0)
    }

    // MARK: - Todo Lists

    @Test("Active - [ ] unchecked has list paragraph style")
    @MainActor func activeTodoUnchecked() {
        let editor = makeEditor()
        editor.loadContent("- [ ] todo")
        activateBlock(0, in: editor)

        let a = attrs(at: 0, in: editor)
        let ps = a[.paragraphStyle] as? NSParagraphStyle
        #expect(ps != nil)
        #expect(ps!.headIndent > 0)
    }

    // MARK: - Blockquotes

    @Test("Active > quote has dimmed > prefix")
    @MainActor func activeBlockquote() {
        let editor = makeEditor()
        editor.loadContent("> quote")
        activateBlock(0, in: editor)

        let delimColor = fgColor(at: 0, in: editor)
        #expect(delimColor == NSColor.tertiaryLabelColor)
    }

    @Test("Active blockquote line shows its raw text")
    @MainActor func activeBlockquoteLine() {
        let editor = makeEditor()
        editor.loadContent("> line1\n> line2\nother")
        activateBlock(0, in: editor)

        // Each > line is its own block now
        let text = displayText(for: 0, in: editor)
        #expect(text == "> line1")
    }
}

// ============================================================================
// MARK: - Block Styling: Non-Active Block (delimiters hidden, not stripped)
// ============================================================================

@Suite("Integration — Block Styling (Non-Active Block)")
struct BlockStylingNonActiveTests {

    // MARK: - Headings

    @Test("Non-active # heading has bold scaled font, # is hidden")
    @MainActor func nonActiveH1() {
        let editor = makeEditor()
        editor.loadContent("# Title\nother")
        activateBlock(1, in: editor)

        // Text storage still contains raw "# Title"
        let text = displayText(for: 0, in: editor)
        #expect(text == "# Title")
        // # is hidden (cursor not in this block)
        #expect(fgColor(at: 0, in: editor) == NSColor.clear)
        #expect(font(at: 0, in: editor)!.pointSize < 1.0)
        // Content has bold scaled font
        let f = font(at: 2, in: editor)!
        let expectedSize = editor.bodyFont.pointSize * 1.5
        #expect(abs(f.pointSize - expectedSize) < 0.1)
        #expect(NSFontManager.shared.traits(of: f).contains(.boldFontMask))
    }

    @Test("Non-active ## heading applies correct scale")
    @MainActor func nonActiveH2() {
        let editor = makeEditor()
        editor.loadContent("## Sub\nother")
        activateBlock(1, in: editor)

        let f = font(at: 3, in: editor)!
        let expectedSize = editor.bodyFont.pointSize * 1.3
        #expect(abs(f.pointSize - expectedSize) < 0.1)
    }

    @Test("Non-active ### heading applies correct scale")
    @MainActor func nonActiveH3() {
        let editor = makeEditor()
        editor.loadContent("### Sec\nother")
        activateBlock(1, in: editor)

        let f = font(at: 4, in: editor)!
        let expectedSize = editor.bodyFont.pointSize * 1.15
        #expect(abs(f.pointSize - expectedSize) < 0.1)
    }

    // MARK: - Bullet Lists

    @Test("Non-active list item has raw text, dimmed marker, indent")
    @MainActor func nonActiveBulletList() {
        let editor = makeEditor()
        editor.loadContent("- apples\nother")
        activateBlock(1, in: editor)

        // Text unchanged
        let text = displayText(for: 0, in: editor)
        #expect(text == "- apples")
        // Bullet `-` is dimmed
        let delimColor = fgColor(at: 0, in: editor)
        #expect(delimColor == NSColor.tertiaryLabelColor)
        // Has indent
        let a = attrs(at: 0, in: editor)
        let ps = a[.paragraphStyle] as? NSParagraphStyle
        #expect(ps != nil)
        #expect(ps!.headIndent > 0)
    }

    // MARK: - Numbered Lists

    @Test("Non-active ordered list has dimmed number and indent")
    @MainActor func nonActiveNumberedList() {
        let editor = makeEditor()
        editor.loadContent("1. first\nother")
        activateBlock(1, in: editor)

        let text = displayText(for: 0, in: editor)
        #expect(text == "1. first")
        let numColor = fgColor(at: 0, in: editor)
        #expect(numColor == NSColor.tertiaryLabelColor)
    }

    // MARK: - Todo Lists

    @Test("Non-active - [ ] has dimmed prefix, circle attachment on [")
    @MainActor func nonActiveTodoUnchecked() {
        let editor = makeEditor()
        editor.loadContent("- [ ] task\nother")
        activateBlock(1, in: editor)

        let text = displayText(for: 0, in: editor)
        #expect(text == "- [ ] task")
        // "- " prefix (offsets 0-1) is hidden (zero-width + clear)
        #expect(isHidden(at: 0, in: editor.textStorage!))
        // "[" (offset 2) has a text attachment (circle icon)
        let a = attrs(at: 2, in: editor)
        #expect(a[.attachment] is NSTextAttachment)
        // " ]" (offsets 3-4) are hidden
        let hiddenA = attrs(at: 3, in: editor)
        let hiddenF = hiddenA[.font] as? NSFont
        #expect(hiddenF != nil && hiddenF!.pointSize < 1.0)
    }

    @Test("Non-active - [x] has dimmed prefix, filled circle attachment, strikethrough content")
    @MainActor func nonActiveTodoChecked() {
        let editor = makeEditor()
        editor.loadContent("- [x] done\nother")
        activateBlock(1, in: editor)

        let text = displayText(for: 0, in: editor)
        #expect(text == "- [x] done")
        // "- " prefix (offsets 0-1) is hidden (zero-width + clear)
        #expect(isHidden(at: 0, in: editor.textStorage!))
        // "[" (offset 2) has a text attachment (filled circle icon)
        let a = attrs(at: 2, in: editor)
        #expect(a[.attachment] is NSTextAttachment)
        // "x]" (offsets 3-4) are hidden
        let hiddenA = attrs(at: 3, in: editor)
        let hiddenF = hiddenA[.font] as? NSFont
        #expect(hiddenF != nil && hiddenF!.pointSize < 1.0)
        // Content "done" should have strikethrough
        let ca = attrs(at: 6, in: editor)
        #expect(ca[.strikethroughStyle] as? Int == NSUnderlineStyle.single.rawValue)
    }

    // MARK: - Multi-Level Lists

    @Test("Non-active nested bullet (2 spaces) has dimmed marker")
    @MainActor func nonActiveNestedBullet() {
        let editor = makeEditor()
        editor.loadContent("  - nested\nother")
        activateBlock(1, in: editor)

        let text = displayText(for: 0, in: editor)
        #expect(text == "  - nested")
        // The `-` at offset 2 is dimmed
        #expect(fgColor(at: 2, in: editor) == NSColor.tertiaryLabelColor)
    }

    @Test("Non-active deeply-indented bullet (4 spaces) has dimmed marker")
    @MainActor func nonActiveDeeplyNestedBullet() {
        let editor = makeEditor()
        editor.loadContent("    - deep\nother")
        activateBlock(1, in: editor)

        let text = displayText(for: 0, in: editor)
        #expect(text == "    - deep")
        // The `-` at offset 4 is dimmed
        #expect(fgColor(at: 4, in: editor) == NSColor.tertiaryLabelColor)
    }

    // MARK: - Blockquotes

    @Test("Non-active > quote: prefix invisible (width-preserving), content has secondary color")
    @MainActor func nonActiveBlockquote() {
        let editor = makeEditor()
        editor.loadContent("> wise words\nother")
        activateBlock(1, in: editor)

        let text = displayText(for: 0, in: editor)
        #expect(text == "> wise words")
        // > is invisible but preserves width (color clear, font NOT shrunk)
        #expect(fgColor(at: 0, in: editor) == NSColor.clear)
        #expect(font(at: 0, in: editor)!.pointSize >= 1.0)
        // Content has secondary label color
        let contentColor = fgColor(at: 2, in: editor)
        #expect(contentColor == NSColor.secondaryLabelColor)
    }

    @Test("Non-active > quote has blockquote paragraph style with text block")
    @MainActor func nonActiveBlockquoteParagraphStyle() {
        let editor = makeEditor()
        let styled = editor.styleBlock("> wise words")

        // Paragraph style must be on offset 0 (the >) so NSTextView uses it
        // for the whole paragraph (it reads the style from the first char).
        let a0 = styled.attributes(at: 0, effectiveRange: nil)
        let ps0 = a0[.paragraphStyle] as? NSParagraphStyle
        #expect(ps0 != nil)
        #expect(!ps0!.textBlocks.isEmpty)

        // Content should also have the same paragraph style
        let a2 = styled.attributes(at: 2, effectiveRange: nil)
        let ps2 = a2[.paragraphStyle] as? NSParagraphStyle
        #expect(ps2 != nil)
        #expect(!ps2!.textBlocks.isEmpty)
    }

    @Test("Non-active consecutive blockquote lines: each > hidden independently")
    @MainActor func nonActiveConsecutiveBlockquoteLines() {
        let editor = makeEditor()
        // Each > line is its own block; activate the last block
        editor.loadContent("> line1\n> line2\nother")
        activateBlock(2, in: editor)

        // Block 0: "> line1", > hidden
        let text0 = displayText(for: 0, in: editor)
        #expect(text0 == "> line1")
        #expect(fgColor(at: 0, in: editor) == NSColor.clear)

        // Block 1: "> line2", > hidden
        let text1 = displayText(for: 1, in: editor)
        #expect(text1 == "> line2")
        let b1 = editor.displayRanges[1].location
        #expect(fgColor(at: b1, in: editor) == NSColor.clear)
    }

    @Test("Non-active blockquote line has text block style")
    @MainActor func nonActiveBlockquoteLineParagraphStyle() {
        let editor = makeEditor()
        let styled = editor.styleBlock("> wise words")

        // Paragraph style at offset 0 (first char) carries the text block border
        let a0 = styled.attributes(at: 0, effectiveRange: nil)
        let ps0 = a0[.paragraphStyle] as? NSParagraphStyle
        #expect(ps0 != nil)
        #expect(!ps0!.textBlocks.isEmpty)
    }

    // MARK: - Nested Content

    @Test("Non-active bold inside blockquote: all delimiters hidden")
    @MainActor func nonActiveBoldInBlockquote() {
        let editor = makeEditor()
        editor.loadContent("> **important**\nother")
        activateBlock(1, in: editor)

        let text = displayText(for: 0, in: editor)
        #expect(text == "> **important**")
        // > is hidden (cursor not in this block)
        #expect(fgColor(at: 0, in: editor) == NSColor.clear)
        // ** delimiters at 2,3 should be hidden (inline)
        let ts = editor.textStorage!
        let f = ts.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        #expect(f != nil)
        #expect(f!.pointSize < 1.0)
        // Content "important" at 4-12 should have bold font
        let contentFont = font(at: 4, in: editor)!
        #expect(NSFontManager.shared.traits(of: contentFont).contains(.boldFontMask))
    }
}

// ============================================================================
// MARK: - Table
// ============================================================================

@Suite("Integration — Table (Active Block)")
struct TableActiveTests {

    @Test("Active table shows raw markdown")
    @MainActor func activeShowsRaw() {
        let editor = makeEditor()
        editor.loadContent("| A | B |\n| --- | --- |\n| 1 | 2 |\nother")
        activateBlock(0, in: editor)

        let text = displayText(for: 0, in: editor)
        #expect(text.contains("| A | B |"))
        #expect(text.contains("| --- | --- |"))
    }

    @Test("Active table pipes are dimmed")
    @MainActor func activePipesDimmed() {
        let editor = makeEditor()
        editor.loadContent("| A | B |\n| --- | --- |\n| 1 | 2 |\nother")
        activateBlock(0, in: editor)

        let color = fgColor(at: 0, in: editor)
        #expect(color == NSColor.tertiaryLabelColor)
    }
}

@Suite("Integration — Table (Non-Active Block)")
struct TableNonActiveTests {

    @Test("Non-active table header is bold")
    @MainActor func nonActiveHeaderBold() {
        let editor = makeEditor()
        editor.loadContent("| A | B |\n| --- | --- |\n| 1 | 2 |\nother")
        activateBlock(1, in: editor)

        let base = editor.displayRanges[0].location
        // "A" at base+2 should be bold
        let f = font(at: base + 2, in: editor)!
        let traits = NSFontManager.shared.traits(of: f)
        #expect(traits.contains(.boldFontMask))
    }

    @Test("Non-active table outer pipes are hidden, inner pipes are secondary")
    @MainActor func nonActivePipesStyling() {
        let editor = makeEditor()
        editor.loadContent("| A | B |\n| --- | --- |\n| 1 | 2 |\nother")
        activateBlock(1, in: editor)

        let base = editor.displayRanges[0].location
        // Outer pipe at base+0 is hidden
        let outerF = font(at: base, in: editor)!
        #expect(outerF.pointSize < 1.0)
        // Inner pipe at base+4 is secondary color
        let color = fgColor(at: base + 4, in: editor)
        #expect(color == NSColor.secondaryLabelColor)
    }
}

// ============================================================================
// MARK: - Code Block
// ============================================================================

@Suite("Integration — Code Block (Active Block)")
struct CodeBlockActiveTests {

    @Test("Active code block shows raw markdown with fences")
    @MainActor func activeShowsRaw() {
        let editor = makeEditor()
        editor.loadContent("```\nhello\n```\nother")
        activateBlock(0, in: editor)

        let text = displayText(for: 0, in: editor)
        #expect(text == "```\nhello\n```")
    }

    @Test("Active code block fences are dimmed")
    @MainActor func activeFencesDimmed() {
        let editor = makeEditor()
        editor.loadContent("```\nhello\n```\nother")
        activateBlock(0, in: editor)

        let color = fgColor(at: 0, in: editor)
        #expect(color == NSColor.tertiaryLabelColor)
    }

    @Test("Active code block content has monospace font")
    @MainActor func activeContentMonospace() {
        let editor = makeEditor()
        editor.loadContent("```\nhello\n```\nother")
        activateBlock(0, in: editor)

        let f = font(at: 4, in: editor)!
        #expect(f.isFixedPitch)
    }
}

@Suite("Integration — Code Block (Non-Active Block)")
struct CodeBlockNonActiveTests {

    @Test("Non-active code block shows raw text, fences are dimmed")
    @MainActor func nonActiveFencesDimmed() {
        let editor = makeEditor()
        editor.loadContent("```\nhello\n```\nother")
        activateBlock(1, in: editor)

        // Text storage has the raw text
        let text = displayText(for: 0, in: editor)
        #expect(text == "```\nhello\n```")
        // Fences dimmed
        let color = fgColor(at: 0, in: editor)
        #expect(color == NSColor.tertiaryLabelColor)
    }

    @Test("Non-active code block content has monospace font")
    @MainActor func nonActiveMonospace() {
        let editor = makeEditor()
        editor.loadContent("```\nhello\n```\nother")
        activateBlock(1, in: editor)

        // Content "hello" at offset 4
        let f = font(at: 4, in: editor)!
        #expect(f.isFixedPitch)
    }

    @Test("Non-active code block content has code color")
    @MainActor func nonActiveCodeColor() {
        let editor = makeEditor()
        editor.loadContent("```\nhello\n```\nother")
        activateBlock(1, in: editor)

        let color = fgColor(at: 4, in: editor)
        #expect(color != nil)
    }
}

// ============================================================================
// MARK: - Block Transition
// ============================================================================

@Suite("Integration — Block Transition")
struct BlockTransitionTests {

    @Test("Text storage always contains raw markdown regardless of active block")
    @MainActor func textStorageAlwaysRaw() {
        let editor = makeEditor()
        editor.loadContent("**bold**\nplain")

        activateBlock(0, in: editor)
        #expect(editor.textStorage!.string == "**bold**\nplain")

        activateBlock(1, in: editor)
        #expect(editor.textStorage!.string == "**bold**\nplain")
    }

    @Test("Switching active block changes which delimiters are visible")
    @MainActor func switchingBlockChangesDelimiterVisibility() {
        let editor = makeEditor()
        editor.loadContent("**bold**\n*italic*")

        // Block 0 active: ** delimiters dimmed (visible)
        activateBlock(0, in: editor)
        let dimColor = fgColor(at: 0, in: editor)
        #expect(dimColor == NSColor.tertiaryLabelColor)

        // Switch to block 1: block 0's ** delimiters become hidden
        activateBlock(1, in: editor)
        let ts = editor.textStorage!
        let f = ts.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(f != nil)
        #expect(f!.pointSize < 1.0)  // hidden
    }

    @Test("Multiple blocks: all inline delimiters hidden except active token")
    @MainActor func multipleBlocksDelimiterHiding() {
        let editor = makeEditor()
        editor.loadContent("**a**\n*b*\n`c`")

        activateBlock(1, in: editor)

        let ts = editor.textStorage!
        // Block 0 "**a**": ** at 0,1 should be hidden
        let f0 = ts.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(f0!.pointSize < 1.0)
        // Block 2 "`c`": ` at 10 should be hidden
        let f2 = ts.attribute(.font, at: 10, effectiveRange: nil) as? NSFont
        #expect(f2!.pointSize < 1.0)
    }
}

// ============================================================================
// MARK: - Thematic Break
// ============================================================================

@Suite("Integration — Thematic Break (Active Block)")
struct ThematicBreakActiveTests {

    @Test("Active --- is dimmed")
    @MainActor func activeDashDimmed() {
        let editor = makeEditor()
        editor.loadContent("---")
        activateBlock(0, in: editor)

        let color = fgColor(at: 0, in: editor)
        #expect(color == NSColor.tertiaryLabelColor)
    }

    @Test("Active *** is dimmed")
    @MainActor func activeAsteriskDimmed() {
        let editor = makeEditor()
        editor.loadContent("***")
        activateBlock(0, in: editor)

        let color = fgColor(at: 0, in: editor)
        #expect(color == NSColor.tertiaryLabelColor)
    }

    @Test("Active --- shows raw markdown text")
    @MainActor func activeShowsRaw() {
        let editor = makeEditor()
        editor.loadContent("---")
        activateBlock(0, in: editor)

        let text = displayText(for: 0, in: editor)
        #expect(text == "---")
    }
}

@Suite("Integration — Thematic Break (Non-Active Block)")
struct ThematicBreakNonActiveTests {

    @Test("Non-active --- is hidden with horizontal line paragraph style")
    @MainActor func nonActiveDashHorizontalLine() {
        let editor = makeEditor()
        editor.loadContent("---\nother")
        activateBlock(1, in: editor)

        // Raw text still present
        let text = displayText(for: 0, in: editor)
        #expect(text == "---")
        // Characters are hidden (visual line rendered via NSTextBlock)
        #expect(isHidden(at: 0, in: editor.textStorage!))
        // Paragraph style has an NSTextBlock
        let a = attrs(at: 0, in: editor)
        let ps = a[.paragraphStyle] as? NSParagraphStyle
        #expect(ps != nil)
        #expect(!ps!.textBlocks.isEmpty)
    }

    @Test("Non-active *** is hidden with horizontal line paragraph style")
    @MainActor func nonActiveAsteriskHorizontalLine() {
        let editor = makeEditor()
        editor.loadContent("***\nother")
        activateBlock(1, in: editor)

        let text = displayText(for: 0, in: editor)
        #expect(text == "***")
        #expect(isHidden(at: 0, in: editor.textStorage!))
        let a = attrs(at: 0, in: editor)
        let ps = a[.paragraphStyle] as? NSParagraphStyle
        #expect(ps != nil)
        #expect(!ps!.textBlocks.isEmpty)
    }
}

// ============================================================================
// MARK: - Image
// ============================================================================

@Suite("Integration — Image (Active Block)")
struct ImageActiveTests {

    @Test("Active ![alt](url) shows raw markdown")
    @MainActor func activeShowsRaw() {
        let editor = makeEditor()
        editor.loadContent("![photo](https://example.com/img.png)")
        activateBlock(0, in: editor)

        let text = displayText(for: 0, in: editor)
        #expect(text == "![photo](https://example.com/img.png)")
    }

    @Test("Active image alt text has accent color")
    @MainActor func activeImageAccentColor() {
        let editor = makeEditor()
        editor.loadContent("![alt](url)")
        activateBlock(0, in: editor)

        let color = fgColor(at: 2, in: editor)
        #expect(color != nil)
    }

    @Test("Active image delimiters are dimmed")
    @MainActor func activeImageDimmedDelimiters() {
        let editor = makeEditor()
        editor.loadContent("![alt](url)")
        activateBlock(0, in: editor)

        let delimColor = fgColor(at: 0, in: editor)
        #expect(delimColor == NSColor.tertiaryLabelColor)
    }
}

@Suite("Integration — Image (Non-Active Block)")
struct ImageNonActiveTests {

    @Test("Non-active image: delimiters hidden, alt text styled")
    @MainActor func nonActiveImageDelimitersHidden() {
        let editor = makeEditor()
        editor.loadContent("![photo](url)\nother")
        activateBlock(1, in: editor)

        // Text storage has raw text
        let text = displayText(for: 0, in: editor)
        #expect(text == "![photo](url)")
        // Delimiters hidden
        let ts = editor.textStorage!
        let f = ts.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(f!.pointSize < 1.0)
    }

    @Test("Non-active image has italic font on content")
    @MainActor func nonActiveImageItalic() {
        let editor = makeEditor()
        editor.loadContent("![photo](url)\nother")
        activateBlock(1, in: editor)

        // "photo" is at positions 2-6
        let f = font(at: 2, in: editor)!
        #expect(NSFontManager.shared.traits(of: f).contains(.italicFontMask))
    }

    @Test("Non-active image content has accent color")
    @MainActor func nonActiveImageAccentColor() {
        let editor = makeEditor()
        editor.loadContent("![photo](url)\nother")
        activateBlock(1, in: editor)

        let color = fgColor(at: 2, in: editor)
        #expect(color != nil)
    }
}

// ============================================================================
// MARK: - Line Break
// ============================================================================

@Suite("Integration — Line Break (Active Block)")
struct LineBreakActiveTests {

    @Test("Active trailing backslash shows raw markdown")
    @MainActor func activeShowsRaw() {
        let editor = makeEditor()
        editor.loadContent("hello\\")
        activateBlock(0, in: editor)

        let text = displayText(for: 0, in: editor)
        #expect(text == "hello\\")
    }

    @Test("Active trailing backslash is dimmed when cursor is inside token")
    @MainActor func activeBackslashDimmed() {
        let editor = makeEditor()
        editor.loadContent("hello\\")
        // Place cursor at the backslash (offset 5) so it's the active token
        editor.recompose(cursorInRaw: 5)

        let color = fgColor(at: 5, in: editor)
        #expect(color == NSColor.tertiaryLabelColor)
    }
}

@Suite("Integration — Line Break (Non-Active Block)")
struct LineBreakNonActiveTests {

    @Test("Non-active trailing backslash is hidden")
    @MainActor func nonActiveBackslashHidden() {
        let editor = makeEditor()
        editor.loadContent("hello\\\nother")
        activateBlock(1, in: editor)

        // Text storage still has backslash
        let text = displayText(for: 0, in: editor)
        #expect(text == "hello\\")
        // But it's hidden
        let ts = editor.textStorage!
        let f = ts.attribute(.font, at: 5, effectiveRange: nil) as? NSFont
        #expect(f!.pointSize < 1.0)
    }

    @Test("Text without backslash renders unchanged when non-active")
    @MainActor func noBackslashUnchanged() {
        let editor = makeEditor()
        editor.loadContent("plain text\nother")
        activateBlock(1, in: editor)

        let text = displayText(for: 0, in: editor)
        #expect(text == "plain text")
    }
}

// ============================================================================
// MARK: - SoftBreak
// ============================================================================

@Suite("Integration — SoftBreak")
struct SoftBreakTests {

    @Test("Each line is a separate block (inherent soft break)")
    @MainActor func linesAreSeparateBlocks() {
        let editor = makeEditor()
        editor.loadContent("first\nsecond\nthird")

        #expect(editor.blocks.count == 3)
        #expect(editor.blocks[0].content == "first")
        #expect(editor.blocks[1].content == "second")
        #expect(editor.blocks[2].content == "third")
    }

    @Test("Pressing Enter creates a new block (soft break)")
    @MainActor func enterCreatesNewBlock() {
        let editor = makeEditor()
        type("hello", into: editor)
        pressEnter(in: editor)
        type("world", into: editor)

        #expect(editor.blocks.count == 2)
        #expect(editor.blocks[0].content == "hello")
        #expect(editor.blocks[1].content == "world")
    }
}
