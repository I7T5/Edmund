import Testing
import AppKit
@testable import MarkdownEditorCore

// ============================================================================
// MARK: - Features: Undo/Redo
// ============================================================================

@Suite("Integration — Undo/Redo")
struct UndoRedoIntegrationTests {

    @Test("Undo typing then redo restores text and rawSource")
    @MainActor func undoRedoTyping() {
        let editor = makeEditor()
        type("hello", into: editor)
        #expect(editor.rawSource == "hello")

        editor.undo(nil)
        #expect(editor.rawSource == "")

        editor.redo(nil)
        #expect(editor.rawSource == "hello")
    }

    @Test("Undo across blocks: type, Enter, type, undo all")
    @MainActor func undoAcrossBlocks() {
        let editor = makeEditor()
        type("line1", into: editor)
        pressEnter(in: editor)
        type("line2", into: editor)
        #expect(editor.blocks.count == 2)

        editor.undo(nil)  // undo "line2"
        #expect(editor.rawSource == "line1\n")
        editor.undo(nil)  // undo Enter
        #expect(editor.rawSource == "line1")
        editor.undo(nil)  // undo "line1"
        #expect(editor.rawSource == "")
    }

    @Test("Undo paste reverts entire paste in one step")
    @MainActor func undoPaste() {
        let editor = makeEditor()
        paste("pasted text", into: editor)
        #expect(editor.rawSource == "pasted text")

        editor.undo(nil)
        #expect(editor.rawSource == "")
    }

    @Test("New edit after undo clears redo stack")
    @MainActor func editClearsRedo() {
        let editor = makeEditor()
        type("a", into: editor)
        editor.undo(nil)
        type("b", into: editor)
        editor.redo(nil)  // should do nothing
        #expect(editor.rawSource == "b")
    }

    @Test("Undo/redo with markdown content preserves rawSource exactly")
    @MainActor func undoRedoMarkdown() {
        let editor = makeEditor()
        paste("**bold** and *italic*", into: editor)
        let original = editor.rawSource

        editor.undo(nil)
        #expect(editor.rawSource == "")

        editor.redo(nil)
        #expect(editor.rawSource == original)
    }
}

// ============================================================================
// MARK: - Features: Tab to Indent
// ============================================================================

@Suite("Integration — Tab Indent")
struct TabIndentIntegrationTests {

    @Test("Type list, Tab indents, display reflects indent")
    @MainActor func typeAndIndent() {
        let editor = makeEditor()
        type("- item", into: editor)
        editor.insertTab(nil)

        #expect(editor.rawSource == "  - item")
        #expect(editor.textStorage!.string.contains("  - item"))
    }

    @Test("Tab on multi-line list indents all lines")
    @MainActor func multiLineIndent() {
        let editor = makeEditor()
        editor.loadContent("- a\n- b\n- c")

        let len = editor.textStorage!.length
        editor.setSelectedRange(NSRange(location: 0, length: len))
        editor.insertTab(nil)

        #expect(editor.blocks.count == 3)
        for block in editor.blocks {
            #expect(block.content.hasPrefix("  "))
        }
    }

    @Test("Shift-Tab dedents, Undo reverts, Redo re-applies")
    @MainActor func dedentUndoRedo() {
        let editor = makeEditor()
        editor.loadContent("  - item")
        editor.setSelectedRange(NSRange(location: 0, length: 0))

        editor.insertBacktab(nil)
        #expect(editor.rawSource == "- item")

        editor.undo(nil)
        #expect(editor.rawSource == "  - item")

        editor.redo(nil)
        #expect(editor.rawSource == "- item")
    }

    @Test("Tab on non-list line inserts tab character, not indent")
    @MainActor func tabOnPlainText() {
        let editor = makeEditor()
        editor.loadContent("plain text")
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        editor.insertTab(nil)

        #expect(editor.rawSource.contains("\t"))
    }

    @Test("Tab on mixed ordered/unordered list indents all")
    @MainActor func tabMixedList() {
        let editor = makeEditor()
        editor.loadContent("- bullet\n1. numbered")
        let len = editor.textStorage!.length
        editor.setSelectedRange(NSRange(location: 0, length: len))
        editor.insertTab(nil)

        #expect(editor.rawSource == "  - bullet\n  1. numbered")
    }

    @Test("Multiple indent/dedent cycles are stable")
    @MainActor func multipleIndentCycles() {
        let editor = makeEditor()
        editor.loadContent("- item")
        editor.setSelectedRange(NSRange(location: 0, length: 0))

        // Indent twice
        editor.insertTab(nil)
        editor.insertTab(nil)
        #expect(editor.rawSource == "    - item")

        // Dedent twice
        editor.insertBacktab(nil)
        editor.insertBacktab(nil)
        #expect(editor.rawSource == "- item")
    }
}

// ============================================================================
// MARK: - Appearance: Font
// ============================================================================

@Suite("Integration — Font")
struct FontIntegrationTests {

    @Test("Default font is used in base attributes")
    @MainActor func defaultFont() {
        let editor = makeEditor()
        editor.loadContent("hello")
        activateBlock(0, in: editor)

        let f = font(at: 0, in: editor)
        #expect(f == editor.bodyFont)
    }

    @Test("applyTheme changes body font and recomposes")
    @MainActor func applyThemeChangesFont() {
        let editor = makeEditor()
        editor.loadContent("hello")

        // Set to a known font first so we have a stable baseline
        var theme = editor.theme
        theme.fontName = "Menlo"
        theme.fontSize = 12
        editor.applyTheme(theme)
        #expect(editor.bodyFont.familyName == "Menlo")

        // Now change to a different font
        theme.fontName = "Helvetica"
        theme.fontSize = 20
        editor.applyTheme(theme)
        #expect(editor.bodyFont.familyName == "Helvetica")
        #expect(editor.bodyFont.pointSize == 20)

        // Verify text storage uses the new font
        let f = font(at: 0, in: editor)
        #expect(f?.familyName == "Helvetica")
        #expect(f?.pointSize == 20)
    }

    @Test("applyTheme affects bold rendering")
    @MainActor func applyThemeAffectsBold() {
        let editor = makeEditor()
        editor.loadContent("**bold**")
        var theme = editor.theme
        theme.fontName = "Helvetica"
        theme.fontSize = 24
        editor.applyTheme(theme)
        activateBlock(0, in: editor)

        let f = font(at: 2, in: editor)!
        #expect(NSFontManager.shared.traits(of: f).contains(.boldFontMask))
        #expect(f.pointSize == 24)
    }

    @Test("applyTheme affects heading scale")
    @MainActor func applyThemeAffectsHeading() {
        let editor = makeEditor()
        editor.loadContent("# Title")
        var theme = editor.theme
        theme.fontName = "Helvetica"
        theme.fontSize = 20
        editor.applyTheme(theme)
        activateBlock(0, in: editor)

        let f = font(at: 2, in: editor)!
        let expectedSize = 20.0 * 1.5
        #expect(abs(f.pointSize - expectedSize) < 0.1)
    }

    @Test("applyTheme affects non-active block rendering")
    @MainActor func applyThemeInactive() {
        let editor = makeEditor()
        editor.loadContent("**bold**\nother")
        var theme = editor.theme
        theme.fontName = "Helvetica"
        theme.fontSize = 18
        editor.applyTheme(theme)
        activateBlock(1, in: editor)

        // In word-level rendering, offset 0 is a delimiter (hidden font).
        // Content "bold" starts at offset 2.
        let base = editor.displayRanges[0].location
        let f = font(at: base + 2, in: editor)!
        #expect(NSFontManager.shared.traits(of: f).contains(.boldFontMask))
        #expect(f.pointSize == 18)
    }

    @Test("Theme persists to UserDefaults")
    @MainActor func themePersistence() {
        let editor = makeEditor()
        var theme = editor.theme
        theme.fontName = "Courier"
        theme.fontSize = 14
        theme.accentHex = "#FF0000"
        theme.lineSpacing = 8
        editor.applyTheme(theme)

        let savedName = UserDefaults.standard.string(forKey: "EditorFontName")
        let savedSize = UserDefaults.standard.float(forKey: "EditorFontSize")
        let savedAccent = UserDefaults.standard.string(forKey: "EditorAccentHex")
        let savedSpacing = UserDefaults.standard.float(forKey: "EditorLineSpacing")
        #expect(savedName == "Courier")
        #expect(savedSize == 14)
        #expect(savedAccent == "#FF0000")
        #expect(savedSpacing == 8)
    }

    @Test("Invalid font name falls back to system font")
    @MainActor func invalidFontFallback() {
        let editor = makeEditor()
        var theme = editor.theme
        theme.fontName = "NonExistentFont12345"
        theme.fontSize = 16
        editor.applyTheme(theme)

        #expect(editor.bodyFont.pointSize == 16)
        // Should be a system font since the name is invalid
        #expect(editor.bodyFont == NSFont.systemFont(ofSize: 16))
    }
}

// ============================================================================
// MARK: - Appearance: Colors & Dark Mode
// ============================================================================

@Suite("Integration — Appearance")
struct AppearanceIntegrationTests {

    @Test("Editor background uses textBackgroundColor")
    @MainActor func editorBackground() {
        let editor = makeEditor()
        #expect(editor.backgroundColor == NSColor.textBackgroundColor)
    }

    @Test("Insertion point uses textColor")
    @MainActor func insertionPoint() {
        let editor = makeEditor()
        #expect(editor.insertionPointColor == NSColor.textColor)
    }

    @Test("Body text uses textColor")
    @MainActor func bodyTextColor() {
        let editor = makeEditor()
        editor.loadContent("hello")
        activateBlock(0, in: editor)

        let color = fgColor(at: 0, in: editor)
        #expect(color == NSColor.textColor)
    }

    @Test("Selection attributes use accent color with alpha")
    @MainActor func selectionAttributes() {
        let editor = makeEditor()
        let selAttrs = editor.selectedTextAttributes
        let bg = selAttrs[.backgroundColor] as? NSColor
        #expect(bg != nil)
    }

    @Test("viewDidChangeEffectiveAppearance recomposes")
    @MainActor func appearanceChange() {
        let editor = makeEditor()
        editor.loadContent("**bold**")
        activateBlock(0, in: editor)

        // Trigger appearance change callback
        editor.viewDidChangeEffectiveAppearance()

        // Editor should still have correct content after recompose
        #expect(editor.rawSource == "**bold**")
        let display = editor.textStorage!.string
        #expect(display == "**bold**")
    }

    @Test("Accent color is used for link text in active block")
    @MainActor func accentColorActiveLink() {
        let editor = makeEditor()
        editor.loadContent("[link](url)")
        activateBlock(0, in: editor)

        let color = fgColor(at: 1, in: editor)
        #expect(color == editor.accentColor)
    }

    @Test("Code color is used for inline code in both active and non-active")
    @MainActor func codeColorBothStates() {
        let editor = makeEditor()
        editor.loadContent("`active`\n`inactive`")

        // Active block 0: content at offset 1
        activateBlock(0, in: editor)
        let activeColor = fgColor(at: 1, in: editor)
        #expect(activeColor == editor.codeColor)

        // Switch to block 1, making block 0 non-active.
        // Offset 0 is backtick (hidden), content "active" starts at offset 1.
        activateBlock(1, in: editor)
        let nonActiveColor = fgColor(at: editor.displayRanges[0].location + 1, in: editor)
        #expect(nonActiveColor == editor.codeColor)
    }

    @Test("Active token delimiters are dimmed, non-active token delimiters are hidden")
    @MainActor func delimiterDimming() {
        let editor = makeEditor()
        // "**bold** *italic* `code`"
        //  0123456789012345678901234
        editor.loadContent("**bold** *italic* `code`")
        activateBlock(0, in: editor)

        // Cursor at 0 → inside bold token. Bold delimiters dimmed.
        #expect(fgColor(at: 0, in: editor) == NSColor.tertiaryLabelColor)
        // Italic and code delimiters hidden (cursor not inside those tokens)
        #expect(fgColor(at: 9, in: editor) == NSColor.clear)
        #expect(fgColor(at: 18, in: editor) == NSColor.clear)
    }
}

// ============================================================================
// MARK: - Multi-block Document Integration
// ============================================================================

@Suite("Integration — Full Document")
struct FullDocumentIntegrationTests {

    @Test("Rich document: heading, paragraph, list, quote all render")
    @MainActor func richDocument() {
        let editor = makeEditor()
        editor.loadContent("# Title\nSome text\n- item\n> quote")

        // Make block 2 active (the list item)
        activateBlock(2, in: editor)

        // Block 0 (heading, non-active): raw text preserved, markers hidden
        let h = displayText(for: 0, in: editor)
        #expect(h == "# Title")
        // Heading marker "#" at offset 0 is hidden. Content has bold font.
        let hBase = editor.displayRanges[0].location
        #expect(fgColor(at: hBase, in: editor) == NSColor.clear)
        let hf = font(at: hBase + 2, in: editor)!
        #expect(NSFontManager.shared.traits(of: hf).contains(.boldFontMask))

        // Block 1 (plain, non-active): "Some text"
        let p = displayText(for: 1, in: editor)
        #expect(p == "Some text")

        // Block 2 (list, active): "- item" (raw)
        let li = displayText(for: 2, in: editor)
        #expect(li == "- item")

        // Block 3 (quote, non-active): raw text preserved, ">" hidden
        let q = displayText(for: 3, in: editor)
        #expect(q == "> quote")
        let qBase = editor.displayRanges[3].location
        #expect(fgColor(at: qBase, in: editor) == NSColor.clear)
    }

    @Test("Type complete document from scratch, verify structure")
    @MainActor func typeFromScratch() {
        let editor = makeEditor()

        type("# My Doc", into: editor)
        pressEnter(in: editor)
        type("A paragraph.", into: editor)
        pressEnter(in: editor)
        type("- first", into: editor)
        pressEnter(in: editor)
        type("- second", into: editor)

        #expect(editor.blocks.count == 4)
        #expect(editor.rawSource == "# My Doc\nA paragraph.\n- first\n- second")
    }

    @Test("Paste markdown document, navigate blocks, verify rendering")
    @MainActor func pasteAndNavigate() {
        let editor = makeEditor()
        let md = "**Bold title**\n*Italic subtitle*\n`code block`\n~~deleted~~\n==highlight=="
        editor.loadContent(md)

        // Activate block 2 (code)
        activateBlock(2, in: editor)

        // Block 0 non-active: raw text preserved, delimiters hidden, content bold
        #expect(displayText(for: 0, in: editor) == "**Bold title**")
        let b0 = editor.displayRanges[0].location
        let bf = font(at: b0 + 2, in: editor)!  // content starts after **
        #expect(NSFontManager.shared.traits(of: bf).contains(.boldFontMask))

        // Block 1 non-active: raw text preserved, delimiters hidden, content italic
        #expect(displayText(for: 1, in: editor) == "*Italic subtitle*")
        let b1 = editor.displayRanges[1].location
        let itf = font(at: b1 + 1, in: editor)!  // content starts after *
        #expect(NSFontManager.shared.traits(of: itf).contains(.italicFontMask))

        // Block 2 active: "`code block`" (raw)
        #expect(displayText(for: 2, in: editor) == "`code block`")

        // Block 3 non-active: raw text preserved, delimiters hidden, content has strikethrough
        #expect(displayText(for: 3, in: editor) == "~~deleted~~")
        let b3 = editor.displayRanges[3].location
        let a3 = attrs(at: b3 + 2, in: editor)  // content starts after ~~
        #expect(a3[.strikethroughStyle] as? Int == NSUnderlineStyle.single.rawValue)

        // Block 4 non-active: raw text preserved, delimiters hidden, content has background
        #expect(displayText(for: 4, in: editor) == "==highlight==")
        let b4 = editor.displayRanges[4].location
        let a4 = attrs(at: b4 + 2, in: editor)  // content starts after ==
        #expect(a4[.backgroundColor] != nil)
    }
}
