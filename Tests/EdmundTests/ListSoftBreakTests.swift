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
