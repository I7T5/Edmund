import Testing
import AppKit
@testable import EdmundCore

/// Mapping a document offset to the table cell that holds it — the primitive
/// the popup cell editor opens on.

@Suite("Table cell resolution")
@MainActor
struct TableCellResolutionTests {

    private let table = "| a | bb |\n|---|---|\n| x | yy |"

    /// Offset of the first occurrence of `needle`, as a document offset.
    private func offset(of needle: String, in editor: EditorTextView) -> Int {
        (editor.rawSource as NSString).range(of: needle).location
    }

    private func load(_ text: String) -> EditorTextView {
        let editor = makeEditor()
        editor.loadContent(text)
        return editor
    }

    @Test("A header cell resolves to row 0 and its own column")
    func headerCell() {
        let editor = load("lead\n\n\(table)\n")
        guard let cell = editor.tableCell(atRawOffset: offset(of: "bb", in: editor)) else {
            Issue.record("no cell resolved")
            return
        }
        #expect(cell.row == 0)
        #expect(cell.column == 1)
        #expect(editor.blocks[cell.blockIndex].kind == .table)
        #expect((editor.rawSource as NSString).substring(with: cell.contentRange) == " bb ")
    }

    @Test("A body cell resolves to its own row and column")
    func bodyCell() {
        let editor = load(table)
        guard let cell = editor.tableCell(atRawOffset: offset(of: "yy", in: editor)) else {
            Issue.record("no cell resolved")
            return
        }
        #expect(cell.row == 2)
        #expect(cell.column == 1)
        #expect((editor.rawSource as NSString).substring(with: cell.contentRange) == " yy ")
    }

    @Test("The content range excludes the pipes and includes the padding spaces")
    func contentRangeBounds() {
        let editor = load(table)
        guard let cell = editor.tableCell(atRawOffset: offset(of: "a", in: editor)) else {
            Issue.record("no cell resolved")
            return
        }
        let raw = editor.rawSource as NSString
        #expect(raw.substring(with: cell.contentRange) == " a ")
        #expect(raw.character(at: cell.contentRange.location - 1) == 0x7C)      // leading |
        #expect(raw.character(at: cell.contentRange.upperBound) == 0x7C)        // trailing |
    }

    @Test("The separator row resolves to nothing")
    func separatorRowIsNotEditable() {
        let editor = load(table)
        let sep = offset(of: "|---|", in: editor)
        #expect(editor.tableCell(atRawOffset: sep + 2) == nil)
    }

    @Test("An offset outside any table resolves to nothing")
    func outsideATable() {
        let editor = load("lead paragraph\n\n\(table)\n")
        #expect(editor.tableCell(atRawOffset: offset(of: "lead", in: editor)) == nil)
    }

    @Test("An escaped pipe stays inside its cell rather than splitting it")
    func escapedPipeIsContent() {
        let editor = load("| a \\| b | c |\n|---|---|\n| x | y |")
        guard let cell = editor.tableCell(atRawOffset: offset(of: "a", in: editor)) else {
            Issue.record("no cell resolved")
            return
        }
        #expect(cell.column == 0)
        #expect((editor.rawSource as NSString).substring(with: cell.contentRange) == " a \\| b ")
    }

    @Test("A row written without outer pipes still resolves")
    func bareRowForm() {
        let editor = load("a | b\n---|---\nx | y")
        guard let cell = editor.tableCell(atRawOffset: offset(of: "y", in: editor)) else {
            Issue.record("no cell resolved")
            return
        }
        #expect(cell.row == 2)
        #expect(cell.column == 1)
    }

    /// A right- or center-aligned column hangs its padding kern on the pipe
    /// *before* it, so that pipe covers real screen width and a click can land
    /// on it. Pipes therefore belong to the cell that follows them.
    @Test("An offset on a pipe belongs to the cell after it")
    func pipeBelongsToTheFollowingCell() {
        let editor = load("| a | bb |\n|---|--:|\n| x | yy |")
        let raw = editor.rawSource as NSString
        // The pipe between the two header cells.
        let shared = raw.range(of: "|", options: [],
                               range: NSRange(location: 1, length: raw.length - 1)).location
        guard let cell = editor.tableCell(atRawOffset: shared) else {
            Issue.record("no cell resolved")
            return
        }
        #expect(cell.column == 1)
    }

    @Test("An offset on the row's opening pipe belongs to the first cell")
    func openingPipeBelongsToFirstCell() {
        let editor = load(table)
        #expect(editor.tableCell(atRawOffset: 0)?.column == 0)
    }

    @Test("An offset on the row's closing pipe clamps to the last cell")
    func closingPipeClampsToLastCell() {
        let editor = load(table)
        let firstNewline = (editor.rawSource as NSString).range(of: "\n").location
        guard let cell = editor.tableCell(atRawOffset: firstNewline - 1) else {
            Issue.record("no cell resolved")
            return
        }
        #expect(cell.row == 0)
        #expect(cell.column == 1)
    }

    @Test("Two tables resolve to different blocks")
    func twoTables() {
        let editor = load("\(table)\n\nbetween\n\n\(table)\n")
        let raw = editor.rawSource as NSString
        let first = editor.tableCell(atRawOffset: raw.range(of: "yy").location)
        let secondRange = raw.range(of: "yy", options: .backwards)
        let second = editor.tableCell(atRawOffset: secondRange.location)
        #expect(first != nil)
        #expect(second != nil)
        #expect(first?.blockIndex != second?.blockIndex)
    }
}
