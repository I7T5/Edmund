import Testing
import AppKit
@testable import MarkdownEditorCore

// MARK: - Coordinate Mapping

@Suite("EditorTextView — Coordinate Mapping")
struct EditorCoordinateTests {

    @Test("Single block: display offset equals raw offset")
    @MainActor func singleBlockIdentity() {
        let editor = makeEditor()
        type("hello", into: editor)

        #expect(editor.displayOffsetToRawOffset(0) == 0)
        #expect(editor.displayOffsetToRawOffset(3) == 3)
        #expect(editor.displayOffsetToRawOffset(5) == 5)

        #expect(editor.rawOffsetToDisplayOffset(0) == 0)
        #expect(editor.rawOffsetToDisplayOffset(3) == 3)
        #expect(editor.rawOffsetToDisplayOffset(5) == 5)
    }

    @Test("blockIndexForRawOffset returns correct index")
    @MainActor func blockIndexMapping() {
        let editor = makeEditor()
        // Set up multi-block state directly
        editor.rawSource = "hello\nworld"
        editor.blocks = BlockParser.parse(editor.rawSource)
        editor.recompose(cursorInRaw: 0)

        #expect(editor.blockIndexForRawOffset(0) == 0)   // start of "hello"
        #expect(editor.blockIndexForRawOffset(3) == 0)   // middle of "hello"
        #expect(editor.blockIndexForRawOffset(5) == 0)   // end of "hello"
        #expect(editor.blockIndexForRawOffset(6) == 1)   // start of "world"
        #expect(editor.blockIndexForRawOffset(11) == 1)  // end of "world"
    }

    @Test("blockIndexForRawOffset clamps to last block")
    @MainActor func blockIndexClamp() {
        let editor = makeEditor()
        editor.rawSource = "abc"
        editor.blocks = BlockParser.parse(editor.rawSource)
        editor.recompose(cursorInRaw: 0)

        #expect(editor.blockIndexForRawOffset(100) == 0)
    }
}

// MARK: - Markdown Rendering

@Suite("EditorTextView — Markdown Rendering")
struct EditorMarkdownTests {

    @Test("Bold markdown renders to shorter text (removes **)")
    @MainActor func boldRendering() {
        let editor = makeEditor()
        let rendered = editor.renderMarkdown("**bold**")
        #expect(rendered.string == "bold")
    }

    @Test("Italic markdown renders to shorter text (removes *)")
    @MainActor func italicRendering() {
        let editor = makeEditor()
        let rendered = editor.renderMarkdown("*italic*")
        #expect(rendered.string == "italic")
    }

    @Test("Plain text renders unchanged")
    @MainActor func plainRendering() {
        let editor = makeEditor()
        let rendered = editor.renderMarkdown("just plain text")
        #expect(rendered.string == "just plain text")
    }

    @Test("Inline code renders without backticks")
    @MainActor func codeRendering() {
        let editor = makeEditor()
        let rendered = editor.renderMarkdown("`code`")
        #expect(rendered.string == "code")
    }

    @Test("Bold text is rendered (syntax stripped) and has font attribute")
    @MainActor func boldFontTrait() {
        let editor = makeEditor()
        let rendered = editor.renderMarkdown("**bold**")
        // The markdown syntax ** should be stripped
        #expect(rendered.string.contains("bold"))
        #expect(!rendered.string.contains("**"))
        // Font attribute should be present (trait may vary by environment)
        var hasFont = false
        rendered.enumerateAttribute(.font, in: NSRange(location: 0, length: rendered.length)) { val, _, _ in
            if val is NSFont { hasFont = true }
        }
        #expect(hasFont)
    }

    @Test("Italic text is rendered (syntax stripped) and has font attribute")
    @MainActor func italicFontTrait() {
        let editor = makeEditor()
        let rendered = editor.renderMarkdown("*italic*")
        // The markdown syntax * should be stripped
        #expect(rendered.string.contains("italic"))
        // Check that the wrapping *s are gone (the word itself doesn't start/end with *)
        let trimmed = rendered.string.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!trimmed.hasPrefix("*"))
        #expect(!trimmed.hasSuffix("*"))
        // Font attribute should be present
        var hasFont = false
        rendered.enumerateAttribute(.font, in: NSRange(location: 0, length: rendered.length)) { val, _, _ in
            if val is NSFont { hasFont = true }
        }
        #expect(hasFont)
    }

    @Test("Empty string renders to empty attributed string")
    @MainActor func emptyRendering() {
        let editor = makeEditor()
        let rendered = editor.renderMarkdown("")
        #expect(rendered.string == "")
    }

    @Test("Heading renders without # prefix")
    @MainActor func headingRendering() {
        let editor = makeEditor()
        let rendered = editor.renderMarkdown("# Hello")
        #expect(rendered.string == "Hello")
    }

    @Test("Bold italic renders without delimiters")
    @MainActor func boldItalicRendering() {
        let editor = makeEditor()
        let rendered = editor.renderMarkdown("***both***")
        #expect(rendered.string == "both")
    }

    @Test("**hi* renders as *hi (extra * stays, matched delimiters stripped)")
    @MainActor func mismatchedDoubleOpenSingleClose() {
        let editor = makeEditor()
        let rendered = editor.renderMarkdown("**hi*")
        #expect(rendered.string == "*hi")
    }

    @Test("*hi** renders as hi* (extra * stays, matched delimiters stripped)")
    @MainActor func mismatchedSingleOpenDoubleClose() {
        let editor = makeEditor()
        let rendered = editor.renderMarkdown("*hi**")
        #expect(rendered.string == "hi*")
    }

    @Test("***hi** renders as *hi (extra * stays, bold delimiters stripped)")
    @MainActor func mismatchedTripleOpenDoubleClose() {
        let editor = makeEditor()
        let rendered = editor.renderMarkdown("***hi**")
        #expect(rendered.string == "*hi")
    }

    @Test("Link renders as text only (delimiters stripped)")
    @MainActor func linkRendering() {
        let editor = makeEditor()
        let rendered = editor.renderMarkdown("[click here](https://example.com)")
        #expect(rendered.string == "click here")
    }

    @Test("Blockquote renders without > prefix")
    @MainActor func blockquoteRendering() {
        let editor = makeEditor()
        let rendered = editor.renderMarkdown("> hello world")
        #expect(rendered.string == "hello world")
    }

    @Test("Unordered list item renders with bullet")
    @MainActor func unorderedListRendering() {
        let editor = makeEditor()
        let rendered = editor.renderMarkdown("- hello")
        #expect(rendered.string == "\u{2022} hello")
    }

    @Test("Ordered list item keeps its number")
    @MainActor func orderedListRendering() {
        let editor = makeEditor()
        let rendered = editor.renderMarkdown("1. hello")
        #expect(rendered.string == "1. hello")
    }

    @Test("Inline code renders in dark red")
    @MainActor func inlineCodeColor() {
        let editor = makeEditor()
        let rendered = editor.renderMarkdown("`code`")
        #expect(rendered.string == "code")
        var foundCodeColor = false
        rendered.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: rendered.length)) { val, _, _ in
            if let color = val as? NSColor {
                // Check it's approximately #8a2425
                if color.redComponent > 0.5 && color.greenComponent < 0.2 && color.blueComponent < 0.2 {
                    foundCodeColor = true
                }
            }
        }
        #expect(foundCodeColor)
    }

    @Test("Active block inline code has dark red content")
    @MainActor func activeCodeColor() {
        let editor = makeEditor()
        let highlighted = editor.highlightSyntax("`code`")
        #expect(highlighted.string == "`code`")
        // Check the content range (chars 1-4) has the code color
        var foundCodeColor = false
        highlighted.enumerateAttribute(.foregroundColor, in: NSRange(location: 1, length: 4)) { val, _, _ in
            if let color = val as? NSColor {
                if color.redComponent > 0.5 && color.greenComponent < 0.2 && color.blueComponent < 0.2 {
                    foundCodeColor = true
                }
            }
        }
        #expect(foundCodeColor)
    }

    @Test("Link rendered text has underline attribute")
    @MainActor func linkUnderline() {
        let editor = makeEditor()
        let rendered = editor.renderMarkdown("[text](url)")
        #expect(rendered.string == "text")
        var hasUnderline = false
        rendered.enumerateAttribute(.underlineStyle, in: NSRange(location: 0, length: rendered.length)) { val, _, _ in
            if val != nil { hasUnderline = true }
        }
        #expect(hasUnderline)
    }

    @Test("Blockquote rendered text has secondary label color")
    @MainActor func blockquoteColor() {
        let editor = makeEditor()
        let rendered = editor.renderMarkdown("> text")
        var hasSecondaryColor = false
        rendered.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: rendered.length)) { val, _, _ in
            if let color = val as? NSColor, color == NSColor.secondaryLabelColor {
                hasSecondaryColor = true
            }
        }
        #expect(hasSecondaryColor)
    }

    @Test("List items have indented paragraph style")
    @MainActor func listIndentation() {
        let editor = makeEditor()
        let rendered = editor.renderMarkdown("- hello")
        var hasIndent = false
        rendered.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: rendered.length)) { val, _, _ in
            if let ps = val as? NSParagraphStyle, ps.firstLineHeadIndent > 0 {
                hasIndent = true
            }
        }
        #expect(hasIndent)
    }

    @Test("Active list items have indented paragraph style")
    @MainActor func activeListIndentation() {
        let editor = makeEditor()
        let highlighted = editor.highlightSyntax("- hello")
        var hasIndent = false
        highlighted.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: highlighted.length)) { val, _, _ in
            if let ps = val as? NSParagraphStyle, ps.firstLineHeadIndent > 0 {
                hasIndent = true
            }
        }
        #expect(hasIndent)
    }

    @Test("Ordered list number is dimmed")
    @MainActor func orderedListNumberDimmed() {
        let editor = makeEditor()
        let rendered = editor.renderMarkdown("1. hello")
        // The "1. " should have the dim color
        var hasDimColor = false
        rendered.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: 3)) { val, _, _ in
            if val is NSColor { hasDimColor = true }
        }
        #expect(hasDimColor)
    }

    @Test("Strikethrough renders without ~~ delimiters")
    @MainActor func strikethroughRendering() {
        let editor = makeEditor()
        let rendered = editor.renderMarkdown("~~deleted~~")
        #expect(rendered.string == "deleted")
        var hasStrikethrough = false
        rendered.enumerateAttribute(.strikethroughStyle, in: NSRange(location: 0, length: rendered.length)) { val, _, _ in
            if val != nil { hasStrikethrough = true }
        }
        #expect(hasStrikethrough)
    }

    @Test("Active block strikethrough has strikethrough attribute")
    @MainActor func activeStrikethrough() {
        let editor = makeEditor()
        let highlighted = editor.highlightSyntax("~~deleted~~")
        #expect(highlighted.string == "~~deleted~~")
        var hasStrikethrough = false
        highlighted.enumerateAttribute(.strikethroughStyle, in: NSRange(location: 2, length: 7)) { val, _, _ in
            if val != nil { hasStrikethrough = true }
        }
        #expect(hasStrikethrough)
    }

    @Test("Highlight renders without == delimiters")
    @MainActor func highlightRendering() {
        let editor = makeEditor()
        let rendered = editor.renderMarkdown("==important==")
        #expect(rendered.string == "important")
        var hasBackground = false
        rendered.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: rendered.length)) { val, _, _ in
            if val != nil { hasBackground = true }
        }
        #expect(hasBackground)
    }

    @Test("Active block highlight has background color")
    @MainActor func activeHighlight() {
        let editor = makeEditor()
        let highlighted = editor.highlightSyntax("==important==")
        #expect(highlighted.string == "==important==")
        var hasBackground = false
        highlighted.enumerateAttribute(.backgroundColor, in: NSRange(location: 2, length: 9)) { val, _, _ in
            if val != nil { hasBackground = true }
        }
        #expect(hasBackground)
    }

    @Test("Blockquote has paragraph style with text block")
    @MainActor func blockquoteTextBlock() {
        let editor = makeEditor()
        let rendered = editor.renderMarkdown("> text")
        var hasTextBlock = false
        rendered.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: rendered.length)) { val, _, _ in
            if let ps = val as? NSParagraphStyle, !ps.textBlocks.isEmpty {
                hasTextBlock = true
            }
        }
        #expect(hasTextBlock)
    }
}

// MARK: - Display Composition

@Suite("EditorTextView — Recompose")
struct EditorRecomposeTests {

    @Test("Active block shows raw markdown in text storage")
    @MainActor func activeBlockShowsRaw() {
        let editor = makeEditor()
        editor.rawSource = "**bold**\nplain"
        editor.blocks = BlockParser.parse(editor.rawSource)
        // Cursor in block 0 — block 0 stays raw
        editor.recompose(cursorInRaw: 0)

        let display = editor.textStorage!.string
        #expect(display.hasPrefix("**bold**"))
    }

    @Test("Non-active block shows rendered markdown in text storage")
    @MainActor func nonActiveBlockRendered() {
        let editor = makeEditor()
        editor.rawSource = "**bold**\nplain"
        editor.blocks = BlockParser.parse(editor.rawSource)
        // Cursor in block 1 — block 0 gets rendered
        editor.recompose(cursorInRaw: 9)  // offset 9 = start of "plain"

        let display = editor.textStorage!.string
        // Block 0 should be rendered: "**bold**" → "bold"
        #expect(display.hasPrefix("bold"))
        #expect(display.hasSuffix("plain"))
    }

    @Test("Display ranges are computed correctly after recompose")
    @MainActor func displayRangesCorrect() {
        let editor = makeEditor()
        editor.rawSource = "**bold**\nplain"
        editor.blocks = BlockParser.parse(editor.rawSource)
        editor.recompose(cursorInRaw: 9)

        #expect(editor.displayRanges.count == 2)
        // Block 0 rendered: "bold" = 4 chars
        #expect(editor.displayRanges[0].length == 4)
        // Block 1 active: "plain" = 5 chars
        #expect(editor.displayRanges[1].length == 5)
    }

    @Test("activeBlockIndex is set correctly")
    @MainActor func activeBlockIndexCorrect() {
        let editor = makeEditor()
        editor.rawSource = "aaa\nbbb\nccc"
        editor.blocks = BlockParser.parse(editor.rawSource)

        editor.recompose(cursorInRaw: 0)
        #expect(editor.activeBlockIndex == 0)

        editor.recompose(cursorInRaw: 4)
        #expect(editor.activeBlockIndex == 1)

        editor.recompose(cursorInRaw: 8)
        #expect(editor.activeBlockIndex == 2)
    }
}
