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

    // MARK: - The caret inside a wrapped cell

    /// A table whose second column can't fit its text: the cell is hidden and
    /// redrawn from a detached layout, which is the case the caret geometry
    /// exists for.
    private let wrapped = "Lead.\n\n| a | \(String(repeating: "overflowing ", count: 12))|\n| ---- | ---- |\n| b | c |\n"

    private func wrappedEditor() -> (EditorTextView, NSRange) {
        let editor = loadEditor(wrapped)
        let cell = (wrapped as NSString).range(of: "overflowing ", options: [])
        let long = NSRange(location: cell.location, length: 12 * 12)
        editor.setSelectedRange(NSRange(location: long.location, length: 0))
        if let b = editor.blocks.firstIndex(where: { $0.kind == .table }) {
            editor.restyleBlock(b, cursorInBlock: long.location - editor.blocks[b].range.location)
        }
        ensureFullLayout(editor)
        layOutViewport(editor)
        return (editor, long)
    }

    private func fragment(_ editor: EditorTextView, at offset: Int)
        -> (DecoratedTextLayoutFragment, Int)? {
        guard let tlm = editor.textLayoutManager,
              let loc = tlm.location(tlm.documentRange.location, offsetBy: offset),
              let frag = tlm.textLayoutFragment(for: loc) as? DecoratedTextLayoutFragment,
              let start = frag.textElement?.elementRange?.location else { return nil }
        return (frag, tlm.offset(from: tlm.documentRange.location, to: start))
    }

    /// The wall this whole change had to get past: the cell's real characters
    /// sit at 0.01pt each, so the layout manager's own caret rect crawls 0.005pt
    /// per character. The rects come from the scratch layout instead.
    @Test("The caret follows the drawn text of a wrapped cell")
    func caretFollowsTheWrappedText() {
        let (editor, long) = wrappedEditor()
        func x(_ off: Int) -> CGFloat? {
            editor.wrappedCellRects(for: NSRange(location: off, length: 0)).first?.minX
        }
        guard let a = x(long.location), let b = x(long.location + 10) else {
            Issue.record("no caret rects")
            return
        }
        #expect(b - a > 20)
    }

    /// The cell wraps, so a late offset has to sit on a lower visual line —
    /// not just further right, which a single long line would also give.
    @Test("The caret drops to the wrapped cell's later lines")
    func caretDropsToTheNextVisualLine() {
        let (editor, long) = wrappedEditor()
        func rect(_ off: Int) -> NSRect? {
            editor.wrappedCellRects(for: NSRange(location: off, length: 0)).first
        }
        guard let first = rect(long.location),
              let last = rect(long.upperBound - 1) else {
            Issue.record("no caret rects")
            return
        }
        #expect(last.minY > first.minY)
    }

    /// The caret rect and the click mapping have to agree, or clicking a
    /// character wouldn't put the caret on it. Checked past the first visual
    /// line, where a line-relative index would have drifted.
    @Test("Caret rects round-trip through the click mapping")
    func caretRoundTripsWithTheClick() {
        let (editor, long) = wrappedEditor()
        guard let (frag, base) = fragment(editor, at: long.location) else {
            Issue.record("no fragment")
            return
        }
        let frame = frag.layoutFragmentFrame
        let origin = editor.textContainerOrigin
        for offset in [long.location + 2, long.location + 60, long.upperBound - 4] {
            guard let rect = editor.wrappedCellRects(
                for: NSRange(location: offset, length: 0)).first else {
                Issue.record("no rect at \(offset)")
                continue
            }
            // A point just inside the character the caret sits before.
            let point = CGPoint(x: rect.minX - frame.minX - origin.x + 1,
                                y: rect.midY - frame.minY - origin.y)
            #expect(frag.cellWrapCharacterIndex(for: point).map { base + $0 } == offset)
        }
    }

    /// Tab selects a cell's text, and a wrapped cell's real characters are
    /// hidden — so without its own highlight the selection would be invisible.
    @Test("A selection in a wrapped cell yields one rect per visual line")
    func selectionSpansTheWrappedLines() {
        let (editor, long) = wrappedEditor()
        let rects = editor.wrappedCellRects(for: long)
        #expect(rects.count > 1)
        #expect(rects.allSatisfy { $0.width > 0 })
    }

    /// Down inside a wrapped cell walks its visual lines instead of leaving the
    /// row, which is what the layout manager's own geometry would do.
    @Test("Down moves within a wrapped cell, then out of it")
    func downWalksTheWrappedLines() {
        let (editor, long) = wrappedEditor()
        editor.setSelectedRange(NSRange(location: long.location + 2, length: 0))
        editor.moveDown(nil)
        let after = editor.selectedRange().location
        #expect(after > long.location + 2)
        #expect(after < long.upperBound)
        // Off the last line there is nothing left to walk, so the key goes back
        // to ordinary movement rather than sticking at the cell's end.
        editor.setSelectedRange(NSRange(location: long.upperBound - 2, length: 0))
        #expect(editor.wrappedCellVerticalOffset(lineDelta: 1) == nil)
    }

    // MARK: - Typing

    /// A space typed at the end of a cell's text must land — you cannot write a
    /// two-word header otherwise. The caret-resting rule pulls a caret out of a
    /// cell's trailing pad for a click or an arrow, but a keystroke is exempt:
    /// the space it just typed is content-in-progress, not pad to step over.
    @Test("A space can be typed inside a cell")
    func spaceTypesInsideACell() {
        let editor = loadEditor(doc)
        let end = (doc as NSString).range(of: "col1").upperBound
        editor.setSelectedRange(NSRange(location: end, length: 0))
        for ch in ["X", " ", "Y"] {
            editor.insertText(ch, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        // The space is in the content, between the two typed characters.
        #expect(editor.rawSource.contains("| col1X Y "))
        // The caret advanced past all three, not stuck before the space.
        let ns = editor.rawSource as NSString
        #expect(editor.selectedRange().location == ns.range(of: "col1X Y").upperBound)
    }

    // MARK: - Return: down a row, or a new one

    @Test("Return moves to the cell below and selects it")
    func returnMovesDownARow() {
        let editor = loadEditor(doc)
        let caret = (doc as NSString).range(of: "c11").upperBound - 1
        editor.setSelectedRange(NSRange(location: caret, length: 0))
        editor.insertNewline(nil)
        #expect(editor.rawSource == doc)   // nothing was split, nothing was added
        #expect((editor.rawSource as NSString).substring(with: editor.selectedRange()) == "c21")
    }

    /// Return from the header inserts a fresh body row directly below it — under
    /// the separator (row 1) — and lands in it, rather than stepping into the
    /// row that was already there. It keeps the column the caret was in.
    @Test("Return from the header inserts a new body row and enters it")
    func returnFromTheHeaderInsertsARow() {
        let editor = loadEditor(doc)
        let caret = (doc as NSString).range(of: "col2").location
        editor.setSelectedRange(NSRange(location: caret, length: 0))
        editor.insertNewline(nil)
        let ns = editor.rawSource as NSString
        // A new empty row now sits between the separator and the old first row.
        #expect(editor.rawSource.contains("| ---- | ---- |\n|  |  |\n| c11 | c12 |"))
        // The caret is in that new row, in the header's column (col2).
        let line = ns.lineRange(for: editor.selectedRange())
        #expect(ns.substring(with: line).trimmingCharacters(in: .newlines) == "|  |  |")
        #expect(editor.selectedRange().location == line.location + 5)   // second column
        // The old rows are untouched.
        #expect(editor.rawSource.contains("| c11 | c12 |"))
        #expect(editor.rawSource.contains("| c21 | c22 |"))
    }

    @Test("Return on the last row adds one")
    func returnOnTheLastRowAddsARow() {
        let editor = loadEditor(doc)
        let caret = (doc as NSString).range(of: "c21").location
        editor.setSelectedRange(NSRange(location: caret, length: 0))
        editor.insertNewline(nil)
        #expect(editor.rawSource.contains("| c21 | c22 |"))   // the cell survived whole
        #expect(editor.rawSource.contains("|  |  |"))          // and a row appeared
        let rows = editor.rawSource.components(separatedBy: "\n")
            .filter { $0.contains("|") }.count
        #expect(rows == 5)   // header, separator, two body rows, the new one
    }

    /// The new row keeps the column the user was in, so Return down a column
    /// carries on down it rather than snapping back to the first cell.
    @Test("The added row keeps the caret's column")
    func addedRowKeepsTheColumn() {
        let editor = loadEditor(doc)
        let caret = (doc as NSString).range(of: "c22").location
        editor.setSelectedRange(NSRange(location: caret, length: 0))
        editor.insertNewline(nil)
        let ns = editor.rawSource as NSString
        let line = ns.lineRange(for: editor.selectedRange())
        #expect(ns.substring(with: line).trimmingCharacters(in: .newlines) == "|  |  |")
        // Second column of `|  |  |`: past the leading pipe, two spaces, a pipe.
        #expect(editor.selectedRange().location == line.location + 5)
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
