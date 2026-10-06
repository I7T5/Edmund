import Testing
import AppKit
@testable import EdmundCore

/// Cutting cells and pasting a grid of them, into a table or beside one.
///
/// Every test runs on a pasteboard of its own: a test suite has no business
/// overwriting the clipboard of whoever is running it.

@Suite("Table cell paste")
@MainActor
struct TableCellPasteTests {

    private let doc = "Intro.\n\n| h1 | h2 |\n| --- | :-: |\n| a | b |\n| c | d |\n"

    private func loadEditor(_ text: String) -> EditorTextView {
        let editor = makeEditor()
        editor.updateContentInset()
        editor.loadContent(text)
        ensureFullLayout(editor)
        layOutViewport(editor)
        return editor
    }

    private func caret(_ editor: EditorTextView, to needle: String) {
        let offset = (editor.rawSource as NSString).range(of: needle).location
        editor.setSelectedRange(NSRange(location: offset, length: 0))
        if let block = editor.blockIndexForRawOffset(offset) {
            editor.restyleBlock(block, cursorInBlock: offset - editor.blocks[block].range.location)
        }
        ensureFullLayout(editor)
        layOutViewport(editor)
    }

    private func tableIndex(_ editor: EditorTextView) -> Int {
        editor.blocks.firstIndex { $0.kind == .table } ?? -1
    }

    private func scratchPasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("edmund-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    // MARK: - Pure helpers

    @Test("Tab-separated text splits into rows, quotes honoured")
    func parsesTSV() {
        #expect(parseTSV("a\tb\nc\td\n") == [["a", "b"], ["c", "d"]])
        #expect(parseTSV("\"x\ty\"\t\"say \"\"hi\"\"\"\r\nz") == [["x\ty", "say \"hi\""], ["z", ""]])
        #expect(parseTSV("\"two\nlines\"\tb") == [["two\nlines", "b"]])
        #expect(parseTSV("") == [])
    }

    @Test("Outside text is made safe for a cell")
    func escapesCells() {
        #expect(tableCellEscaped("a|b") == "a\\|b")
        #expect(tableCellEscaped("a\\|b") == "a\\|b")
        #expect(tableCellEscaped(" two\nlines ") == "two lines")
    }

    @Test("A grid overwrites cells and grows the table to fit")
    func pastedLinesGrow() {
        let lines = ["| h1 | h2 |", "| --- | --- |", "| a | b |"]
        #expect(pastedTableLines(lines, grid: [["x", "y"], ["z", ""]], row: 2, column: 1)
                == ["| h1 | h2 |  |", "| --- | --- | --- |", "| a | x | y |", "|  | z |  |"])
        // From the header, the next row is the first body row.
        #expect(pastedTableLines(lines, grid: [["p"], ["q"]], row: 0, column: 0)
                == ["| p | h2 |", "| --- | --- |", "| q | b |"])
    }

    // MARK: - In the editor

    @Test("Cut empties the cells and puts them on the pasteboard")
    func cutClearsTheCells() throws {
        let editor = loadEditor(doc)
        caret(editor, to: "a")
        editor.selectTableCells(blockIndex: tableIndex(editor), from: (2, 0), to: (3, 1))
        let pasteboard = scratchPasteboard()
        #expect(editor.cutTableCells(to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "a\tb\nc\td")
        let data = try #require(pasteboard.data(forType: TableCellsClip.pasteboardType))
        let clip = try JSONDecoder().decode(TableCellsClip.self, from: data)
        #expect(clip == TableCellsClip(cells: [["a", "b"], ["c", "d"]], aligns: ["---", ":-:"]))
        #expect(editor.rawSource
                == "Intro.\n\n| h1 | h2 |\n| --- | :-: |\n|  |  |\n|  |  |\n")
    }

    @Test("Edmund's cells paste into a table from the caret's cell, as one undo step")
    func clipPastesIntoCells() {
        let editor = loadEditor(doc)
        caret(editor, to: "d")
        let pasteboard = scratchPasteboard()
        pasteboard.declareTypes([TableCellsClip.pasteboardType], owner: nil)
        let clip = TableCellsClip(cells: [["**x**", "y"]], aligns: ["---", "---"])
        pasteboard.setData(try? JSONEncoder().encode(clip), forType: TableCellsClip.pasteboardType)
        #expect(editor.pasteTableCells(from: pasteboard))
        #expect(editor.rawSource
                == "Intro.\n\n| h1 | h2 |  |\n| --- | :-: | --- |\n| a | b |  |\n| c | **x** | y |\n")
        editor.undo(nil)
        #expect(editor.rawSource == doc)
    }

    @Test("A spreadsheet's grid fills cells; a word without a tab is just a word")
    func tabularTextFillsCells() {
        let editor = loadEditor(doc)
        caret(editor, to: "a")
        let grid = scratchPasteboard()
        grid.setString("1\t2\n3\t4", forType: .string)
        #expect(editor.pasteTableCells(from: grid))
        #expect(editor.rawSource == "Intro.\n\n| h1 | h2 |\n| --- | :-: |\n| 1 | 2 |\n| 3 | 4 |\n")

        let word = scratchPasteboard()
        word.setString("plain", forType: .string)
        caret(editor, to: "4")
        #expect(!editor.pasteTableCells(from: word))
    }

    @Test("One value pasted over a block fills every cell of it")
    func singleValueFillsTheBlock() {
        let editor = loadEditor(doc)
        caret(editor, to: "a")
        editor.selectTableCells(blockIndex: tableIndex(editor), from: (2, 0), to: (3, 0))
        let pasteboard = scratchPasteboard()
        pasteboard.setString("0", forType: .tabularText)
        #expect(editor.pasteTableCells(from: pasteboard))
        #expect(editor.rawSource == "Intro.\n\n| h1 | h2 |\n| --- | :-: |\n| 0 | b |\n| 0 | d |\n")
    }

    @Test("Edmund's cells pasted outside a table become a new table")
    func clipOutsideMakesATable() {
        let editor = loadEditor("Before\n\nAfter\n")
        caret(editor, to: "After")
        let pasteboard = scratchPasteboard()
        pasteboard.declareTypes([TableCellsClip.pasteboardType], owner: nil)
        let clip = TableCellsClip(cells: [["h", "k"], ["a", "bb"]], aligns: [":--", "---"])
        pasteboard.setData(try? JSONEncoder().encode(clip), forType: TableCellsClip.pasteboardType)
        #expect(editor.pasteTableCells(from: pasteboard))
        #expect(editor.rawSource
                == "Before\n\n| h   | k   |\n| :-- | --- |\n| a   | bb  |\n\nAfter\n")
        #expect(editor.blocks.contains { $0.kind == .table })
    }

    @Test("Tab-separated text outside a table is left to the ordinary paste")
    func tsvOutsideIsText() {
        let editor = loadEditor("Before\n")
        caret(editor, to: "Before")
        let pasteboard = scratchPasteboard()
        pasteboard.setString("1\t2", forType: .string)
        #expect(!editor.pasteTableCells(from: pasteboard))
    }
}
