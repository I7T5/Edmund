import Testing
import AppKit
@testable import EdmundCore

/// Aligning a table's source once the caret leaves it — invisible on screen,
/// and one undo step with the edit that prompted it.

@Suite("Table format", .serialized)
@MainActor
struct TableFormatTests {

    private func loadEditor(_ text: String) -> EditorTextView {
        let editor = makeEditor()
        editor.updateContentInset()
        editor.loadContent(text)
        ensureFullLayout(editor)
        layOutViewport(editor)
        return editor
    }

    // MARK: - The formatter

    @Test("Columns align in display columns, CJK counting double")
    func alignsWideCharacters() {
        #expect(displayColumns("a") == 1)
        #expect(displayColumns("表") == 2)
        #expect(displayColumns("한") == 2)
        #expect(displayColumns("😀") == 2)
        #expect(displayColumns("e\u{301}") == 1)   // one character, combining accent
        #expect(formattedTableLines(["| 表 | b |", "| --- | --- |", "| aaaa | c |"])
                == ["| 表   | b   |", "| ---- | --- |", "| aaaa | c   |"])
    }

    @Test("A cell past the header's columns is never dropped")
    func keepsExcessText() {
        #expect(formattedTableLines(["| a |", "| --- |", "| b | extra |"]) == nil)
        // An empty one is not text, and goes.
        #expect(formattedTableLines(["| a |", "| --- |", "| b |  |"])
                == ["| a   |", "| --- |", "| b   |"])
    }

    @Test("An aligned table is left alone")
    func alignedIsANoOp() {
        #expect(formattedTableLines(["| a   |", "| --- |", "| b   |"]) == nil)
    }

    // MARK: - On screen

    /// Aligning pads cells in characters, which in a proportional font is not
    /// width. The renderer draws padding past one space as nothing, so the
    /// aligned table is the same table on screen.
    @Test("An aligned table draws exactly as the one it was aligned from")
    func alignedSourceDrawsTheSame() throws {
        let plain = loadEditor("Intro.\n\n| WWWW | b |\n| --- | --- |\n| iiiiiiii | c |\n")
        let aligned = loadEditor(
            "Intro.\n\n| WWWW     | b   |\n| -------- | --- |\n| iiiiiiii | c   |\n")
        let table = { (editor: EditorTextView) in
            editor.blocks.firstIndex { $0.kind == .table } ?? -1
        }
        let a = try #require(plain.tableGrid(blockIndex: table(plain)))
        let b = try #require(aligned.tableGrid(blockIndex: table(aligned)))
        #expect(a.columnEdges.count == b.columnEdges.count)
        for (x, y) in zip(a.columnEdges, b.columnEdges) { #expect(abs(x - y) < 0.5) }
    }

    // MARK: - Leaving the table
    //
    // The format runs from the block-switch hop `selectionDidChange` queues on
    // the main queue, which a synchronous test never drains — so these drive
    // its two halves directly: the edit marks the table, and leaving formats
    // what was marked.

    private func tableIndex(_ editor: EditorTextView) -> Int {
        editor.blocks.firstIndex { $0.kind == .table } ?? -1
    }

    /// Types `text` just after the first `needle` in the document.
    private func typeText(_ text: String, after needle: String, in editor: EditorTextView) {
        let found = (editor.rawSource as NSString).range(of: needle)
        editor.setSelectedRange(NSRange(location: found.upperBound, length: 0))
        type(text, into: editor)
    }

    @Test("Leaving an edited table aligns it; one undo takes back both")
    func leavingFormats() {
        let doc = "Intro.\n\n| a | bb |\n| --- | --- |\n| ccc | d |\n"
        let editor = loadEditor(doc)
        typeText("x", after: "| ccc | d", in: editor)
        #expect(editor.rawSource == "Intro.\n\n| a | bb |\n| --- | --- |\n| ccc | dx |\n")
        #expect(editor.tableFormatPending)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.formatTableOnLeaving(tableIndex(editor))
        #expect(editor.rawSource
                == "Intro.\n\n| a   | bb  |\n| --- | --- |\n| ccc | dx  |\n")
        editor.undo(nil)
        #expect(editor.rawSource == doc)
    }

    @Test("Only an edit marks a table for formatting")
    func visitingDoesNotMark() {
        let doc = "Intro.\n\n| a | bb |\n| --- | --- |\n| ccc | d |\n"
        let editor = loadEditor(doc)
        editor.setSelectedRange(NSRange(location: (doc as NSString).range(of: "ccc").location,
                                        length: 0))
        #expect(!editor.tableFormatPending)
        typeText("x", after: "Intro", in: editor)   // an edit outside any table
        #expect(!editor.tableFormatPending)
    }

    @Test("Never while the caret is in the table")
    func neverUnderTheCaret() {
        let doc = "Intro.\n\n| a | bb |\n| --- | --- |\n| ccc | d |\n"
        let editor = loadEditor(doc)
        typeText("x", after: "| ccc | d", in: editor)
        editor.formatTableOnLeaving(tableIndex(editor))
        #expect(editor.rawSource == "Intro.\n\n| a | bb |\n| --- | --- |\n| ccc | dx |\n")
    }

    @Test("The text after a table keeps its caret when the table is aligned")
    func caretBelowFollowsTheShift() {
        let doc = "| a | bb |\n| --- | --- |\n| ccc | d |\n\nAfter\n"
        let editor = loadEditor(doc)
        typeText("x", after: "| ccc | d", in: editor)
        let after = (editor.rawSource as NSString).range(of: "After").location
        editor.setSelectedRange(NSRange(location: after, length: 0))
        editor.formatTableOnLeaving(tableIndex(editor))
        let ns = editor.rawSource as NSString
        #expect(ns.range(of: "| ccc | dx  |").location != NSNotFound)
        #expect(editor.selectedRange().location == ns.range(of: "After").location)
    }
}
