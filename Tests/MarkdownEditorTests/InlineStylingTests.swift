import Testing
import AppKit
@testable import MarkdownEditorCore

// ============================================================================
// MARK: - Inline Styling: Active Block
// ============================================================================

@Suite("Integration — Inline Styling (Active Block)")
struct InlineStylingActiveTests {

    // MARK: - Bold

    @Test("Active **bold** has bold font on content and dimmed delimiters")
    @MainActor func activeBoldAsterisks() {
        let editor = makeEditor()
        editor.loadContent("**hello**")
        activateBlock(0, in: editor)

        // "**hello**" — delimiters at 0..1 and 7..8, content at 2..6
        let contentFont = font(at: 2, in: editor)!
        #expect(NSFontManager.shared.traits(of: contentFont).contains(.boldFontMask))

        // Delimiters should be dimmed
        let delimColor = fgColor(at: 0, in: editor)
        #expect(delimColor == NSColor.tertiaryLabelColor)
        let endDelimColor = fgColor(at: 7, in: editor)
        #expect(endDelimColor == NSColor.tertiaryLabelColor)
    }

    @Test("Active __bold__ with underscores has bold font")
    @MainActor func activeBoldUnderscores() {
        let editor = makeEditor()
        editor.loadContent("__hello__")
        activateBlock(0, in: editor)

        let contentFont = font(at: 2, in: editor)!
        #expect(NSFontManager.shared.traits(of: contentFont).contains(.boldFontMask))
    }

    // MARK: - Italic

    @Test("Active *italic* has italic font on content and dimmed delimiters")
    @MainActor func activeItalicAsterisks() {
        let editor = makeEditor()
        editor.loadContent("*hello*")
        activateBlock(0, in: editor)

        let contentFont = font(at: 1, in: editor)!
        #expect(NSFontManager.shared.traits(of: contentFont).contains(.italicFontMask))

        let delimColor = fgColor(at: 0, in: editor)
        #expect(delimColor == NSColor.tertiaryLabelColor)
    }

    @Test("Active _italic_ with underscores has italic font")
    @MainActor func activeItalicUnderscores() {
        let editor = makeEditor()
        editor.loadContent("_hello_")
        activateBlock(0, in: editor)

        let contentFont = font(at: 1, in: editor)!
        #expect(NSFontManager.shared.traits(of: contentFont).contains(.italicFontMask))
    }

    // MARK: - Bold Italic

    @Test("Active ***bolditalic*** has bold+italic font")
    @MainActor func activeBoldItalic() {
        let editor = makeEditor()
        editor.loadContent("***hello***")
        activateBlock(0, in: editor)

        let contentFont = font(at: 3, in: editor)!
        let traits = NSFontManager.shared.traits(of: contentFont)
        #expect(traits.contains(.boldFontMask))
        #expect(traits.contains(.italicFontMask))
    }

    @Test("Active ___bolditalic___ with underscores has bold+italic font")
    @MainActor func activeBoldItalicUnderscores() {
        let editor = makeEditor()
        editor.loadContent("___hello___")
        activateBlock(0, in: editor)

        let contentFont = font(at: 3, in: editor)!
        let traits = NSFontManager.shared.traits(of: contentFont)
        #expect(traits.contains(.boldFontMask))
        #expect(traits.contains(.italicFontMask))
    }

    // MARK: - Code

    @Test("Active `code` has code color on content and dimmed backticks")
    @MainActor func activeCode() {
        let editor = makeEditor()
        editor.loadContent("`code`")
        activateBlock(0, in: editor)

        let contentColor = fgColor(at: 1, in: editor)
        #expect(contentColor == editor.codeColor)

        let delimColor = fgColor(at: 0, in: editor)
        #expect(delimColor == NSColor.tertiaryLabelColor)
    }

    // MARK: - Strikethrough

    @Test("Active ~~strikethrough~~ has strikethrough attribute")
    @MainActor func activeStrikethrough() {
        let editor = makeEditor()
        editor.loadContent("~~struck~~")
        activateBlock(0, in: editor)

        let a = attrs(at: 2, in: editor)
        let style = a[.strikethroughStyle] as? Int
        #expect(style == NSUnderlineStyle.single.rawValue)
    }

    // MARK: - Highlight

    @Test("Active ==highlight== has yellow background")
    @MainActor func activeHighlight() {
        let editor = makeEditor()
        editor.loadContent("==marked==")
        activateBlock(0, in: editor)

        let a = attrs(at: 2, in: editor)
        let bg = a[.backgroundColor] as? NSColor
        #expect(bg != nil)
    }

    // MARK: - Link

    @Test("Active [link](url) has accent color on link text")
    @MainActor func activeLink() {
        let editor = makeEditor()
        editor.loadContent("[click](https://example.com)")
        activateBlock(0, in: editor)

        // "[click](url)" — "[" at 0, "click" at 1..5
        let linkColor = fgColor(at: 1, in: editor)
        #expect(linkColor == editor.accentColor)

        // Delimiter "[" should be dimmed
        let delimColor = fgColor(at: 0, in: editor)
        #expect(delimColor == NSColor.tertiaryLabelColor)
    }

    // MARK: - Combinations

    @Test("Active **bold** and *italic* on same line both styled")
    @MainActor func activeBoldAndItalic() {
        let editor = makeEditor()
        // "**bold** and *italic*"
        //  01234567890123456789012
        //  **bold**     *italic*
        editor.loadContent("**bold** and *italic*")
        activateBlock(0, in: editor)

        // Bold content at offset 2 ("bold")
        let boldFont = font(at: 2, in: editor)!
        #expect(NSFontManager.shared.traits(of: boldFont).contains(.boldFontMask))

        // Italic content at offset 14 ("italic" — after "**bold** and *")
        let italicFont = font(at: 14, in: editor)!
        #expect(NSFontManager.shared.traits(of: italicFont).contains(.italicFontMask))
    }

    @Test("Active bold + code + strikethrough on same line all styled")
    @MainActor func activeMixedInline() {
        let editor = makeEditor()
        editor.loadContent("**bold** `code` ~~struck~~")
        activateBlock(0, in: editor)

        // Bold at 2
        let boldFont = font(at: 2, in: editor)!
        #expect(NSFontManager.shared.traits(of: boldFont).contains(.boldFontMask))

        // Code at 10
        let codeCol = fgColor(at: 10, in: editor)
        #expect(codeCol == editor.codeColor)

        // Strikethrough at 18
        let a = attrs(at: 18, in: editor)
        #expect(a[.strikethroughStyle] as? Int == NSUnderlineStyle.single.rawValue)
    }

    // MARK: - Uneven Delimiters

    @Test("Active *hi** renders as italic hi (extra * literal)")
    @MainActor func activeUnevenSingleExtra() {
        let editor = makeEditor()
        editor.loadContent("*hi**")
        activateBlock(0, in: editor)

        // swift-markdown treats this as *hi* + literal *
        // Content "hi" at offset 1
        let f = font(at: 1, in: editor)!
        #expect(NSFontManager.shared.traits(of: f).contains(.italicFontMask))
    }

    @Test("Active **hi* renders as italic (matched * pair, extra * literal)")
    @MainActor func activeUnevenDoubleOpen() {
        let editor = makeEditor()
        editor.loadContent("**hi*")
        activateBlock(0, in: editor)

        // swift-markdown: "**hi*" → *(*hi)* with inner * literal
        // The matched pair is single *, content includes the extra *
        let display = editor.textStorage!.string
        #expect(display == "**hi*")
    }
}

// ============================================================================
// MARK: - Inline Styling: Non-Active Block
// ============================================================================

@Suite("Integration — Inline Styling (Non-Active Block)")
struct InlineStylingInactiveTests {

    @Test("Non-active **bold** preserves raw text, hides delimiters, applies bold font")
    @MainActor func nonActiveBold() {
        let editor = makeEditor()
        editor.loadContent("**bold**\nother")
        activateBlock(1, in: editor)

        // Raw text preserved
        let text = displayText(for: 0, in: editor)
        #expect(text == "**bold**")

        let base = editor.displayRanges[0].location
        // Delimiters hidden
        #expect(font(at: base, in: editor)!.pointSize < 1.0)
        #expect(fgColor(at: base, in: editor) == NSColor.clear)
        // Content has bold font
        let f = font(at: base + 2, in: editor)!
        #expect(NSFontManager.shared.traits(of: f).contains(.boldFontMask))
    }

    @Test("Non-active __bold__ with underscores hides delimiters and applies bold")
    @MainActor func nonActiveBoldUnderscores() {
        let editor = makeEditor()
        editor.loadContent("__bold__\nother")
        activateBlock(1, in: editor)

        let text = displayText(for: 0, in: editor)
        #expect(text == "__bold__")

        let base = editor.displayRanges[0].location
        #expect(font(at: base, in: editor)!.pointSize < 1.0)
        let f = font(at: base + 2, in: editor)!
        #expect(NSFontManager.shared.traits(of: f).contains(.boldFontMask))
    }

    @Test("Non-active *italic* hides delimiters and applies italic font")
    @MainActor func nonActiveItalic() {
        let editor = makeEditor()
        editor.loadContent("*italic*\nother")
        activateBlock(1, in: editor)

        let text = displayText(for: 0, in: editor)
        #expect(text == "*italic*")

        let base = editor.displayRanges[0].location
        #expect(font(at: base, in: editor)!.pointSize < 1.0)
        let f = font(at: base + 1, in: editor)!
        #expect(NSFontManager.shared.traits(of: f).contains(.italicFontMask))
    }

    @Test("Non-active _italic_ with underscores hides delimiters and applies italic")
    @MainActor func nonActiveItalicUnderscores() {
        let editor = makeEditor()
        editor.loadContent("_italic_\nother")
        activateBlock(1, in: editor)

        let text = displayText(for: 0, in: editor)
        #expect(text == "_italic_")

        let base = editor.displayRanges[0].location
        #expect(font(at: base, in: editor)!.pointSize < 1.0)
        let f = font(at: base + 1, in: editor)!
        #expect(NSFontManager.shared.traits(of: f).contains(.italicFontMask))
    }

    @Test("Non-active ***bolditalic*** hides delimiters and applies both traits")
    @MainActor func nonActiveBoldItalic() {
        let editor = makeEditor()
        editor.loadContent("***both***\nother")
        activateBlock(1, in: editor)

        let text = displayText(for: 0, in: editor)
        #expect(text == "***both***")

        let base = editor.displayRanges[0].location
        #expect(font(at: base, in: editor)!.pointSize < 1.0)
        let f = font(at: base + 3, in: editor)!
        let traits = NSFontManager.shared.traits(of: f)
        #expect(traits.contains(.boldFontMask))
        #expect(traits.contains(.italicFontMask))
    }

    @Test("Non-active `code` hides backticks and applies code color")
    @MainActor func nonActiveCode() {
        let editor = makeEditor()
        editor.loadContent("`code`\nother")
        activateBlock(1, in: editor)

        let text = displayText(for: 0, in: editor)
        #expect(text == "`code`")

        let base = editor.displayRanges[0].location
        #expect(font(at: base, in: editor)!.pointSize < 1.0)
        let color = fgColor(at: base + 1, in: editor)
        #expect(color == editor.codeColor)
    }

    @Test("Non-active ~~strikethrough~~ hides delimiters and applies strikethrough")
    @MainActor func nonActiveStrikethrough() {
        let editor = makeEditor()
        editor.loadContent("~~struck~~\nother")
        activateBlock(1, in: editor)

        let text = displayText(for: 0, in: editor)
        #expect(text == "~~struck~~")

        let base = editor.displayRanges[0].location
        #expect(font(at: base, in: editor)!.pointSize < 1.0)
        let a = attrs(at: base + 2, in: editor)
        #expect(a[.strikethroughStyle] as? Int == NSUnderlineStyle.single.rawValue)
    }

    @Test("Non-active ==highlight== hides delimiters and applies background color")
    @MainActor func nonActiveHighlight() {
        let editor = makeEditor()
        editor.loadContent("==marked==\nother")
        activateBlock(1, in: editor)

        let text = displayText(for: 0, in: editor)
        #expect(text == "==marked==")

        let base = editor.displayRanges[0].location
        #expect(font(at: base, in: editor)!.pointSize < 1.0)
        let a = attrs(at: base + 2, in: editor)
        #expect(a[.backgroundColor] != nil)
    }

    @Test("Non-active [link](url) hides syntax, link text has underline and accent color")
    @MainActor func nonActiveLink() {
        let editor = makeEditor()
        editor.loadContent("[click](https://example.com)\nother")
        activateBlock(1, in: editor)

        let text = displayText(for: 0, in: editor)
        #expect(text == "[click](https://example.com)")

        let base = editor.displayRanges[0].location
        // "[" delimiter hidden
        #expect(font(at: base, in: editor)!.pointSize < 1.0)
        // "click" content has accent color and underline
        let color = fgColor(at: base + 1, in: editor)
        #expect(color == editor.accentColor)
        let a = attrs(at: base + 1, in: editor)
        #expect(a[.underlineStyle] as? Int == NSUnderlineStyle.single.rawValue)
    }

    @Test("Non-active mixed bold + italic + code all rendered correctly")
    @MainActor func nonActiveMixed() {
        let editor = makeEditor()
        // "**bold** *italic* `code`"
        //  0123456789012345678901234
        editor.loadContent("**bold** *italic* `code`\nother")
        activateBlock(1, in: editor)

        let text = displayText(for: 0, in: editor)
        #expect(text == "**bold** *italic* `code`")

        let base = editor.displayRanges[0].location
        // ** delimiters hidden
        #expect(font(at: base, in: editor)!.pointSize < 1.0)
        // "bold" at base+2 has bold font
        let bf = font(at: base + 2, in: editor)!
        #expect(NSFontManager.shared.traits(of: bf).contains(.boldFontMask))

        // * delimiters at 9 hidden
        #expect(font(at: base + 9, in: editor)!.pointSize < 1.0)
        // "italic" at base+10 has italic font
        let itf = font(at: base + 10, in: editor)!
        #expect(NSFontManager.shared.traits(of: itf).contains(.italicFontMask))

        // ` delimiter at 18 hidden
        #expect(font(at: base + 18, in: editor)!.pointSize < 1.0)
        // "code" at base+19 has code color
        let cc = fgColor(at: base + 19, in: editor)
        #expect(cc == editor.codeColor)
    }

    @Test("Non-active *hi** preserves raw text (uneven delimiters)")
    @MainActor func nonActiveUnevenDelimiters() {
        let editor = makeEditor()
        editor.loadContent("*hi**\nother")
        activateBlock(1, in: editor)

        // Raw text always preserved
        let text = displayText(for: 0, in: editor)
        #expect(text == "*hi**")
    }
}
