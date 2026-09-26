import Testing
import AppKit
@testable import EdmundCore

// Shift-Return in a list item breaks the line without a new marker: the new
// line is indented to the item's content column, so it stays inside the item
// (a CommonMark continuation paragraph) and is drawn at the item's text column.
@Suite("List soft break (Shift-Return)")
@MainActor
struct ListSoftBreakTests {

    private func softBreak(_ source: String) -> EditorTextView {
        let editor = makeEditor()
        editor.loadContent(source)
        editor.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        #expect(editor.insertListSoftBreak())
        return editor
    }

    @Test("Indents to the item's content column",
          arguments: [("- a", "- a\n  "), ("1. a", "1. a\n   "),
                      ("- [ ] a", "- [ ] a\n      "), ("    - a", "    - a\n      "),
                      ("\t- a", "\t- a\n\t  ")])
    func indentsToContentColumn(source: String, expected: String) {
        #expect(softBreak(source).rawSource == expected)
    }

    @Test("A second Shift-Return keeps the continuation's indent")
    func repeatsOnContinuationLine() {
        let editor = softBreak("- a")
        type("b", into: editor)
        #expect(editor.insertListSoftBreak())
        #expect(editor.rawSource == "- a\n  b\n  ")
    }

    // Before anything is typed the new line is only its indent. It must already
    // sit at the item's text column (spaces hidden), or the caret starts left
    // of where the text will go and jumps on the first keystroke.
    @Test("The caret lands at the item's text column before typing",
          arguments: ["- a", "    - a", "1. a", "- [ ] a"])
    func caretAtTextColumn(source: String) {
        let editor = softBreak(source)
        let caret = editor.selectedRange().location
        let lineStart = editor.blocks[1].range.location
        #expect(editor.listContinuationDepth(ofBlock: 1) != nil)
        let item = editor.textStorage!.attribute(.paragraphStyle, at: 0,
                                                 effectiveRange: nil) as! NSParagraphStyle
        let cont = editor.textStorage!.attribute(.paragraphStyle, at: lineStart,
                                                 effectiveRange: nil) as! NSParagraphStyle
        #expect(cont.firstLineHeadIndent == item.headIndent)
        // All but the last space are hidden; that one stays body-sized (so the
        // line keeps its height) but clear and kerned back to zero width.
        for i in lineStart..<(caret - 1) { #expect(isHidden(at: i, in: editor.textStorage!)) }
        #expect(fgColor(at: caret - 1, in: editor) == NSColor.clear)
        assertMatchesFullRecomposeOracle(editor)
    }

    /// Laid-out x of the insertion point at `offset`.
    private func caretX(_ editor: EditorTextView, at offset: Int) -> CGFloat? {
        ensureFullLayout(editor)
        guard let tlm = editor.textLayoutManager,
              let tcm = tlm.textContentManager,
              let loc = tcm.location(tcm.documentRange.location, offsetBy: offset),
              let range = NSTextRange(location: loc) as NSTextRange? else { return nil }
        var x: CGFloat?
        tlm.enumerateTextSegments(in: range, type: .selection, options: []) { _, frame, _, _ in
            x = frame.minX; return false
        }
        return x
    }

    @Test("Typing the first character doesn't move the caret sideways")
    func caretDoesNotJump() throws {
        let editor = softBreak("- a")
        let before = try #require(caretX(editor, at: editor.selectedRange().location))
        type("b", into: editor)
        let after = try #require(caretX(editor, at: editor.selectedRange().location - 1))
        #expect(abs(before - after) < 0.5)
    }

    /// Laid-out height of the line holding `offset`.
    private func lineHeight(_ editor: EditorTextView, at offset: Int) -> CGFloat? {
        ensureFullLayout(editor)
        guard let tlm = editor.textLayoutManager,
              let tcm = tlm.textContentManager,
              let loc = tcm.location(tcm.documentRange.location, offsetBy: offset),
              let fragment = tlm.textLayoutFragment(for: loc) else { return nil }
        return fragment.textLineFragments.first?.typographicBounds.height
    }

    @Test("The fresh line keeps a body line's height before typing")
    func freshLineKeepsHeight() throws {
        let editor = softBreak("- a")
        let fresh = try #require(lineHeight(editor, at: editor.selectedRange().location - 1))
        type("b", into: editor)
        let typed = try #require(lineHeight(editor, at: editor.selectedRange().location - 1))
        #expect(abs(fresh - typed) < 0.5)
    }

    @Test("Return on a continuation line starts the next item")
    func returnOnContinuation() {
        let e = makeEditor()
        e.loadContent("1. a\n   more")
        e.setSelectedRange(NSRange(location: 12, length: 0))
        e.insertNewline(nil)
        #expect(e.rawSource == "1. a\n   more\n2. ")
    }

    @Test("Return on a still-empty continuation line turns it into the next item")
    func returnOnEmptyContinuation() {
        let editor = softBreak("- a")
        editor.insertNewline(nil)
        #expect(editor.rawSource == "- a\n- ")
    }

    @Test("Outside a list it does nothing")
    func outsideList() {
        let editor = makeEditor()
        editor.loadContent("plain")
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        #expect(!editor.insertListSoftBreak())
        #expect(editor.rawSource == "plain")
    }

    @Test("The continuation is drawn at the item's text column")
    func alignsWithItemText() {
        let editor = makeEditor()
        editor.loadContent("- a\n    - b\n      c\nafter")
        activateBlock(3, in: editor)
        #expect(editor.listContinuationDepth(ofBlock: 2) == 1)
        #expect(editor.listDepth(ofBlock: 2) == nil)
        let item = editor.textStorage!.attribute(.paragraphStyle, at: editor.blocks[1].range.location,
                                                 effectiveRange: nil) as! NSParagraphStyle
        let cont = editor.textStorage!.attribute(.paragraphStyle, at: editor.blocks[2].range.location,
                                                 effectiveRange: nil) as! NSParagraphStyle
        #expect(cont.firstLineHeadIndent == item.headIndent)
        #expect(cont.headIndent == item.headIndent)
        // Its raw spaces are hidden, so they add nothing on top of the indent.
        #expect(isHidden(at: editor.blocks[2].range.location, in: editor.textStorage!))
        // A lazy (unindented) line is not a continuation.
        #expect(editor.listContinuationDepth(ofBlock: 3) == nil)
        assertMatchesFullRecomposeOracle(editor)
    }

    // Parsed alone, a 6-space line is an indented code block; inside an item
    // it's a paragraph continuation and must keep body text and inline styling.
    @Test("A deeply indented continuation is not styled as code")
    func deepContinuationIsProse() {
        let editor = makeEditor()
        editor.loadContent("    - a\n      **b** c\nafter")
        activateBlock(2, in: editor)
        let start = editor.blocks[1].range.location
        let bold = font(at: start + 8, in: editor)!   // "b"
        #expect(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
        #expect(!font(at: start + 12, in: editor)!.isFixedPitch)   // "c"
        #expect(isHidden(at: start + 6, in: editor.textStorage!))  // "**"
        assertMatchesFullRecomposeOracle(editor)
    }

    @Test("Deleting the item re-styles the orphaned continuation")
    func orphanedContinuationRestyles() {
        let editor = makeEditor()
        editor.loadContent("- a\n  b")
        editor.setSelectedRange(NSRange(location: 0, length: 4))
        editor.insertText("", replacementRange: NSRange(location: 0, length: 4))
        #expect(editor.rawSource == "  b")
        #expect(editor.listContinuationDepth(ofBlock: 0) == nil)
        assertMatchesFullRecomposeOracle(editor)
    }
}
