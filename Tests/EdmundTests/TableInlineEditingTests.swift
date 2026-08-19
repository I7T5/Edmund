import Testing
import AppKit
@testable import EdmundCore

/// A table stays rendered with the caret inside it and the cell is edited in
/// the document's own storage, so ordinary typing needs no code and gets no
/// tests here. What needs covering is the two keys whose plain meaning would
/// break the table, and the caret's ability to reach the text at all.

@Suite("Table inline editing")
@MainActor
struct TableInlineEditingTests {

    private let doc = "Lead.\n\n| col1 | col2 |\n| ---- | ---- |\n| c11 | c12 |\n| c21 | c22 |\n"

    private func loadEditor(_ text: String) -> EditorTextView {
        let editor = makeEditor()
        editor.updateContentInset()
        editor.loadContent(text)
        ensureFullLayout(editor)
        layOutViewport(editor)
        return editor
    }

    /// The point of the whole change: putting the caret in a table must not
    /// turn it into pipe soup.
    @Test("A caret in a table leaves it rendered")
    func caretKeepsTheTableRendered() {
        let editor = loadEditor(doc)
        let caret = (doc as NSString).range(of: "c11").location
        editor.setSelectedRange(NSRange(location: caret, length: 0))
        guard let b = editor.blocks.firstIndex(where: { $0.kind == .table }) else {
            Issue.record("no table")
            return
        }
        editor.restyleBlock(b, cursorInBlock: caret - editor.blocks[b].range.location)
        // A rendered row owns its borders and hides its pipes; a raw one does
        // neither. The decoration is the discriminator the fragment reads.
        let storage = editor.textContentStorage!.textStorage!
        let rowStart = (editor.rawSource as NSString)
            .lineRange(for: NSRange(location: caret, length: 0)).location
        #expect(storage.attribute(.blockDecoration, at: rowStart, effectiveRange: nil) != nil)
    }

    /// The wall this change had to get past: a cell too wide for its column is
    /// normally hidden and redrawn from a detached layout, where the caret
    /// cannot follow it — it stays pinned at the column's left edge. The row
    /// being edited keeps its real glyphs instead.
    @Test("The caret can move inside an overflowing cell")
    func caretMovesInsideAnOverflowingCell() {
        let long = String(repeating: "overflowing ", count: 12)
        let text = "Lead.\n\n| col1 | col2 |\n| ---- | ---- |\n| \(long) | b |\n"
        let editor = loadEditor(text)
        let base = (text as NSString).range(of: long).location
        editor.setSelectedRange(NSRange(location: base + 20, length: 0))
        guard let b = editor.blocks.firstIndex(where: { $0.kind == .table }) else {
            Issue.record("no table")
            return
        }
        editor.restyleBlock(b, cursorInBlock: base + 20 - editor.blocks[b].range.location)
        ensureFullLayout(editor)
        layOutViewport(editor)

        func caretX(_ off: Int) -> CGFloat? {
            guard let tlm = editor.textLayoutManager,
                  let cm = tlm.textContentManager,
                  let loc = cm.location(cm.documentRange.location, offsetBy: off),
                  let r = NSTextRange(location: loc, end: loc) else { return nil }
            var x: CGFloat?
            tlm.enumerateTextSegments(in: r, type: .selection,
                                      options: .rangeNotRequired) { _, rect, _, _ in
                x = rect.origin.x
                return false
            }
            return x
        }
        guard let a = caretX(base), let c = caretX(base + 10) else {
            Issue.record("no caret rects")
            return
        }
        // Ten characters of real text, not ten characters of 0.01pt hiddenFont
        // (which moved the caret by 0.05pt in total).
        #expect(c - a > 20)
    }

    // MARK: - Return adds a row

    @Test("Return in a cell adds a row instead of splitting it")
    func returnAddsARow() {
        let editor = loadEditor(doc)
        let caret = (doc as NSString).range(of: "c11").upperBound - 1
        editor.setSelectedRange(NSRange(location: caret, length: 0))
        editor.insertNewline(nil)
        #expect(editor.rawSource.contains("| c11 | c12 |"))   // the cell survived whole
        #expect(editor.rawSource.contains("|  |  |"))          // and a row appeared
        let rows = editor.rawSource.components(separatedBy: "\n")
            .filter { $0.contains("|") }.count
        #expect(rows == 5)   // header, separator, two body rows, the new one
    }

    /// The new row goes below the caret's row, not at the table's end.
    @Test("The new row lands under the caret's row")
    func newRowLandsUnderTheCaret() {
        let editor = loadEditor(doc)
        let caret = (doc as NSString).range(of: "c11").location
        editor.setSelectedRange(NSRange(location: caret, length: 0))
        editor.insertNewline(nil)
        let lines = editor.rawSource.components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { $0.contains("c11") }) else {
            Issue.record("row gone")
            return
        }
        #expect(lines[i + 1].trimmingCharacters(in: .whitespaces) == "|  |  |")
    }

    /// A table written without outer pipes must not gain them — the extra pipe
    /// would parse as another, empty column.
    @Test("A row added to a pipe-less table stays pipe-less")
    func addedRowMatchesTheTablesStyle() {
        let text = "Lead.\n\n a | b \n---|---\n c | d \n"
        let editor = loadEditor(text)
        let caret = (text as NSString).range(of: "c").location
        editor.setSelectedRange(NSRange(location: caret, length: 0))
        editor.insertNewline(nil)
        let added = editor.rawSource.components(separatedBy: "\n")
            .first { $0.contains("|") && !$0.contains("a") && !$0.contains("c")
                     && !$0.contains("-") }
        #expect(added?.hasPrefix("|") == false)
        #expect(added == "  |  ")
    }

    /// Return outside a table is untouched — the list-continuation path still
    /// owns it.
    @Test("Return outside a table is left alone")
    func returnOutsideATableIsUntouched() {
        let editor = loadEditor(doc)
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        editor.insertNewline(nil)
        #expect(editor.rawSource.hasPrefix("Lead.\n\n\n"))
    }

    // MARK: - Tab steps between cells

    @Test("Tab selects the next cell's text")
    func tabStepsToTheNextCell() {
        let editor = loadEditor(doc)
        let caret = (doc as NSString).range(of: "c11").location
        editor.setSelectedRange(NSRange(location: caret, length: 0))
        editor.insertTab(nil)
        #expect((editor.rawSource as NSString).substring(with: editor.selectedRange()) == "c12")
    }

    /// Two Tabs in a row is the case that broke first: the first one leaves a
    /// selection behind, and a cell lookup that insisted on an empty one would
    /// refuse to move again.
    @Test("Tab keeps working from a selected cell")
    func tabRepeats() {
        let editor = loadEditor(doc)
        let caret = (doc as NSString).range(of: "col1").location
        editor.setSelectedRange(NSRange(location: caret, length: 0))
        editor.insertTab(nil)
        #expect((editor.rawSource as NSString).substring(with: editor.selectedRange()) == "col2")
        editor.insertTab(nil)
        // Past the header's last cell, over the separator row, into the body.
        #expect((editor.rawSource as NSString).substring(with: editor.selectedRange()) == "c11")
    }

    @Test("Shift-Tab steps back, and over the separator row")
    func backtabSteps() {
        let editor = loadEditor(doc)
        let caret = (doc as NSString).range(of: "c11").location
        editor.setSelectedRange(NSRange(location: caret, length: 0))
        editor.insertBacktab(nil)
        #expect((editor.rawSource as NSString).substring(with: editor.selectedRange()) == "col2")
    }

    @Test("Tab past the last cell does nothing")
    func tabStopsAtTheEnd() {
        let editor = loadEditor(doc)
        let caret = (doc as NSString).range(of: "c22").location
        editor.setSelectedRange(NSRange(location: caret, length: 0))
        let before = editor.selectedRange()
        editor.insertTab(nil)
        #expect(editor.selectedRange() == before)
    }

    /// While the table shows its raw markdown, the pipes are visible and the
    /// user is editing source by hand — both keys go back to their usual jobs.
    @Test("Raw mode gives Return and Tab back")
    func rawModeRestoresTheKeys() {
        let editor = loadEditor(doc)
        let caret = (doc as NSString).range(of: "c11").location
        editor.setSelectedRange(NSRange(location: caret, length: 0))
        editor.rawTableEditing = true
        #expect(editor.inlineTableCell == nil)
        editor.insertNewline(nil)
        // Plain Return: the line splits where the caret was, which is exactly
        // what in-place editing exists to prevent and what raw mode restores.
        #expect(editor.rawSource.contains("| \nc11 | c12 |"))
    }
}
