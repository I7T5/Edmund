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
        #expect(ps!.firstLineHeadIndent == editor.listIndent)
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
        #expect(ps!.firstLineHeadIndent == editor.listIndent)
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
        #expect(ps!.firstLineHeadIndent == editor.listIndent)
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
}

// ============================================================================
// MARK: - Block Styling: Inactive Block
// ============================================================================

@Suite("Integration — Block Styling (Inactive Block)")
struct BlockStylingInactiveTests {

    // MARK: - Headings

    @Test("Inactive # heading strips prefix, applies bold scaled font")
    @MainActor func inactiveH1() {
        let editor = makeEditor()
        editor.loadContent("# Title\nother")
        activateBlock(1, in: editor)

        let text = displayText(for: 0, in: editor)
        #expect(text == "Title")
        let f = font(at: editor.displayRanges[0].location, in: editor)!
        let expectedSize = editor.bodyFont.pointSize * 1.5
        #expect(abs(f.pointSize - expectedSize) < 0.1)
        #expect(NSFontManager.shared.traits(of: f).contains(.boldFontMask))
    }

    @Test("Inactive ## heading strips prefix, applies correct scale")
    @MainActor func inactiveH2() {
        let editor = makeEditor()
        editor.loadContent("## Sub\nother")
        activateBlock(1, in: editor)

        let text = displayText(for: 0, in: editor)
        #expect(text == "Sub")
        let f = font(at: editor.displayRanges[0].location, in: editor)!
        let expectedSize = editor.bodyFont.pointSize * 1.3
        #expect(abs(f.pointSize - expectedSize) < 0.1)
    }

    @Test("Inactive ### heading strips prefix, applies correct scale")
    @MainActor func inactiveH3() {
        let editor = makeEditor()
        editor.loadContent("### Sec\nother")
        activateBlock(1, in: editor)

        let text = displayText(for: 0, in: editor)
        #expect(text == "Sec")
        let f = font(at: editor.displayRanges[0].location, in: editor)!
        let expectedSize = editor.bodyFont.pointSize * 1.15
        #expect(abs(f.pointSize - expectedSize) < 0.1)
    }

    // MARK: - Bullet Lists

    @Test("Inactive - item shows bullet character and has list paragraph style")
    @MainActor func inactiveBulletList() {
        let editor = makeEditor()
        editor.loadContent("- apples\nother")
        activateBlock(1, in: editor)

        let text = displayText(for: 0, in: editor)
        #expect(text.contains("\u{2022}"))  // bullet •
        #expect(text.contains("apples"))

        let base = editor.displayRanges[0].location
        let a = attrs(at: base, in: editor)
        let ps = a[.paragraphStyle] as? NSParagraphStyle
        #expect(ps != nil)
        #expect(ps!.firstLineHeadIndent == editor.listIndent)
    }

    @Test("Inactive bullet is dimmed")
    @MainActor func inactiveBulletDimmed() {
        let editor = makeEditor()
        editor.loadContent("- apples\nother")
        activateBlock(1, in: editor)

        let base = editor.displayRanges[0].location
        let bulletColor = fgColor(at: base, in: editor)
        #expect(bulletColor == NSColor.tertiaryLabelColor)
    }

    // MARK: - Numbered Lists

    @Test("Inactive 1. item keeps number and has list paragraph style")
    @MainActor func inactiveNumberedList() {
        let editor = makeEditor()
        editor.loadContent("1. first\nother")
        activateBlock(1, in: editor)

        let text = displayText(for: 0, in: editor)
        #expect(text.contains("1."))
        #expect(text.contains("first"))

        let base = editor.displayRanges[0].location
        let a = attrs(at: base, in: editor)
        let ps = a[.paragraphStyle] as? NSParagraphStyle
        #expect(ps != nil)
    }

    @Test("Inactive ordered list number is dimmed")
    @MainActor func inactiveNumberDimmed() {
        let editor = makeEditor()
        editor.loadContent("1. first\nother")
        activateBlock(1, in: editor)

        let base = editor.displayRanges[0].location
        let numColor = fgColor(at: base, in: editor)
        #expect(numColor == NSColor.tertiaryLabelColor)
    }

    // MARK: - Todo Lists

    @Test("Inactive - [ ] unchecked shows open circle")
    @MainActor func inactiveTodoUnchecked() {
        let editor = makeEditor()
        editor.loadContent("- [ ] task\nother")
        activateBlock(1, in: editor)

        let text = displayText(for: 0, in: editor)
        #expect(text.contains("\u{25CB}"))  // ○
        #expect(text.contains("task"))
    }

    @Test("Inactive - [x] checked shows filled circle and strikethrough")
    @MainActor func inactiveTodoChecked() {
        let editor = makeEditor()
        editor.loadContent("- [x] done\nother")
        activateBlock(1, in: editor)

        let text = displayText(for: 0, in: editor)
        #expect(text.contains("\u{25CF}"))  // ●
        #expect(text.contains("done"))

        // "done" should have strikethrough
        let base = editor.displayRanges[0].location
        // Find "done" offset: "● done" → bullet(1) + space(1) + "done" at offset 2
        let doneOffset = base + 2
        let a = attrs(at: doneOffset, in: editor)
        #expect(a[.strikethroughStyle] as? Int == NSUnderlineStyle.single.rawValue)
    }

    // MARK: - Blockquotes

    @Test("Inactive > quote strips prefix, applies secondary label color")
    @MainActor func inactiveBlockquote() {
        let editor = makeEditor()
        editor.loadContent("> wise words\nother")
        activateBlock(1, in: editor)

        let text = displayText(for: 0, in: editor)
        #expect(text == "wise words")
        let color = fgColor(at: editor.displayRanges[0].location, in: editor)
        #expect(color == NSColor.secondaryLabelColor)
    }

    @Test("Inactive > quote has blockquote paragraph style with text block")
    @MainActor func inactiveBlockquoteParagraphStyle() {
        let editor = makeEditor()
        editor.loadContent("> wise words\nother")
        activateBlock(1, in: editor)

        let a = attrs(at: editor.displayRanges[0].location, in: editor)
        let ps = a[.paragraphStyle] as? NSParagraphStyle
        #expect(ps != nil)
        #expect(!ps!.textBlocks.isEmpty)
    }

    // MARK: - Nested Content

    @Test("Inactive bold inside blockquote is rendered")
    @MainActor func inactiveBoldInBlockquote() {
        let editor = makeEditor()
        editor.loadContent("> **important**\nother")
        activateBlock(1, in: editor)

        let text = displayText(for: 0, in: editor)
        // Blockquote ">" stripped, bold "**" stripped
        #expect(text == "important")
        let f = font(at: editor.displayRanges[0].location, in: editor)!
        #expect(NSFontManager.shared.traits(of: f).contains(.boldFontMask))
    }
}

// ============================================================================
// MARK: - Block Transition (Active ↔ Inactive)
// ============================================================================

@Suite("Integration — Block Transition")
struct BlockTransitionTests {

    @Test("Switching from active to inactive renders markdown")
    @MainActor func activeToInactive() {
        let editor = makeEditor()
        editor.loadContent("**bold**\nplain")

        // Block 0 is active (cursor at 0), shows raw markdown
        activateBlock(0, in: editor)
        let activeText = displayText(for: 0, in: editor)
        #expect(activeText == "**bold**")

        // Switch to block 1 — block 0 becomes inactive, rendered
        activateBlock(1, in: editor)
        let inactiveText = displayText(for: 0, in: editor)
        #expect(inactiveText == "bold")
    }

    @Test("Switching from inactive to active shows raw markdown")
    @MainActor func inactiveToActive() {
        let editor = makeEditor()
        editor.loadContent("# Title\ntext")

        // Activate block 1 so block 0 is inactive
        activateBlock(1, in: editor)
        let inactiveText = displayText(for: 0, in: editor)
        #expect(inactiveText == "Title")

        // Activate block 0 — shows raw
        activateBlock(0, in: editor)
        let activeText = displayText(for: 0, in: editor)
        #expect(activeText == "# Title")
    }

    @Test("Multiple blocks: only active block shows raw, others rendered")
    @MainActor func multipleBlocksRendering() {
        let editor = makeEditor()
        editor.loadContent("**a**\n*b*\n`c`")

        activateBlock(1, in: editor)

        // Block 0 inactive: "a" (bold rendered)
        #expect(displayText(for: 0, in: editor) == "a")
        // Block 1 active: "*b*" (raw markdown)
        #expect(displayText(for: 1, in: editor) == "*b*")
        // Block 2 inactive: "c" (code rendered)
        #expect(displayText(for: 2, in: editor) == "c")
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

@Suite("Integration — Thematic Break (Inactive Block)")
struct ThematicBreakInactiveTests {

    @Test("Inactive --- renders as visual divider")
    @MainActor func inactiveDashDivider() {
        let editor = makeEditor()
        editor.loadContent("---\nother")
        activateBlock(1, in: editor)

        let text = displayText(for: 0, in: editor)
        // The divider is 20× ─ (U+2500)
        let expectedDivider = String(repeating: "\u{2500}", count: 20)
        #expect(text == expectedDivider)
    }

    @Test("Inactive --- divider has dimmed color")
    @MainActor func inactiveDividerDimmed() {
        let editor = makeEditor()
        editor.loadContent("---\nother")
        activateBlock(1, in: editor)

        let color = fgColor(at: editor.displayRanges[0].location, in: editor)
        #expect(color == NSColor.tertiaryLabelColor)
    }

    @Test("Inactive *** renders as visual divider")
    @MainActor func inactiveAsteriskDivider() {
        let editor = makeEditor()
        editor.loadContent("***\nother")
        activateBlock(1, in: editor)

        let text = displayText(for: 0, in: editor)
        let expectedDivider = String(repeating: "\u{2500}", count: 20)
        #expect(text == expectedDivider)
    }

    @Test("Thematic break between content blocks renders correctly")
    @MainActor func betweenBlocks() {
        let editor = makeEditor()
        editor.loadContent("above\n\n---\n\nbelow")
        activateBlock(4, in: editor)  // activate "below"

        // Block 2 is "---", should be rendered as divider
        let text = displayText(for: 2, in: editor)
        let expectedDivider = String(repeating: "\u{2500}", count: 20)
        #expect(text == expectedDivider)
    }
}
