import Testing
import AppKit
@testable import EdmundCore

/// Markdown lets a table be written without its outer pipes and without the
/// spaces either side of the inner ones. It renders the same either way, so a
/// table arriving from somewhere else can look nothing like the ones this
/// editor writes — and the spaces, once there, are not content and should not
/// be deletable as if they were.

@Suite("Table normalization")
@MainActor
struct TableNormalizationTests {

    private func loadEditor(_ text: String) -> EditorTextView {
        let editor = makeEditor()
        editor.updateContentInset()
        editor.loadContent(text)
        ensureFullLayout(editor)
        layOutViewport(editor)
        return editor
    }

    // MARK: - The skeleton

    @Test("A row without outer pipes gains them")
    func rowGainsOuterPipes() {
        #expect(normalizedTableRow("a | b") == "| a | b |")
        #expect(normalizedTableRow(" no outer | border ") == "| no outer | border |")
        #expect(normalizedTableRow("---- | ----") == "| ---- | ---- |")
    }

    @Test("Pipes gain exactly one space either side")
    func pipesGainTheirSpaces() {
        #expect(normalizedTableRow("|a|b|") == "| a | b |")
        #expect(normalizedTableRow("|   a   |  b |") == "| a | b |")
    }

    /// The column count is the one thing that must never move: an empty cell is
    /// a cell. `splitTableRow` drops a whitespace-only first or last part to
    /// cope with outer pipes, which is why this does its own splitting.
    @Test("An empty cell survives, wherever it is")
    func emptyCellsSurvive() {
        #expect(normalizedTableRow("| | b | |") == "|  | b |  |")
        #expect(normalizedTableRow("a || b") == "| a |  | b |")
    }

    /// A `\|` is content (GFM Example 200), not a delimiter — on the way in and
    /// on the way out.
    @Test("An escaped pipe stays content")
    func escapedPipeIsContent() {
        #expect(normalizedTableRow("a \\| b | c") == "| a \\| b | c |")
    }

    @Test("Cell content is never reflowed")
    func contentIsUntouched() {
        let row = "| *emph* and `code`  with   inner spaces | b |"
        #expect(normalizedTableRow(row) == "| *emph* and `code`  with   inner spaces | b |")
    }

    @Test("A conventional table reports no change")
    func conventionalTableIsLeftAlone() {
        #expect(normalizedTableBlock("| a | b |\n| --- | --- |\n| c | d |") == nil)
        #expect(normalizedTableBlock("a | b\n--- | ---") == "| a | b |\n| --- | --- |")
    }

    /// Not a table: a line with no pipe at all is not a row, and the block
    /// normaliser must hand it back untouched rather than wrap it in pipes.
    @Test("A pipeless line is not a row")
    func pipelessLineIsUntouched() {
        #expect(normalizedTableRow("just prose") == "just prose")
    }

    // MARK: - Creating

    /// A table this editor makes is already conventional, and stays that way:
    /// the normaliser reporting "no change" is the check, so the two cannot
    /// drift apart if either is edited later.
    @Test("A newly created table needs no tidying")
    func createdTableIsAlreadyConventional() {
        let editor = loadEditor("Intro.\n")
        editor.setSelectedRange(NSRange(location: (editor.rawSource as NSString).length,
                                        length: 0))
        editor.formatTable(nil)
        guard let table = editor.blocks.first(where: { $0.kind == .table }) else {
            Issue.record("no table was created")
            return
        }
        let source = (editor.rawSource as NSString).substring(with: table.range)
        #expect(source.contains("|"))
        #expect(normalizedTableBlock(source) == nil,
                "a freshly created table came out needing normalization: \(source)")
    }

    // MARK: - Pasting

    @Test("Pasting an incomplete table fills its pipes")
    func pasteNormalizesTheTable() {
        let editor = loadEditor("Intro.\n\nno outer | border\n---- | ----\nc21 | c22\n")
        let ns = editor.rawSource as NSString
        editor.normalizeTableDelimiters(in: ns.range(of: "no outer"))
        #expect(editor.rawSource.contains("| no outer | border |"))
        #expect(editor.rawSource.contains("| ---- | ---- |"))
        #expect(editor.rawSource.contains("| c21 | c22 |"))
        // The prose either side is not a table and is not touched.
        #expect(editor.rawSource.hasPrefix("Intro.\n\n"))
    }

    @Test("A span touching no table changes nothing")
    func normalizingSparesEverythingElse() {
        let editor = loadEditor("Intro | not a table.\n\n| a | b |\n| --- | --- |\n| c | d |\n")
        let before = editor.rawSource
        editor.normalizeTableDelimiters(in: NSRange(location: 0, length: 6))
        #expect(editor.rawSource == before)
    }

    // MARK: - The padding is not content

    @Test("Backspace stops at a cell's text")
    func backspaceKeepsThePadding() {
        let editor = loadEditor("Intro.\n\n| a | b |\n| --- | --- |\n| c21 | d |\n")
        let ns = editor.rawSource as NSString
        let text = ns.range(of: "c21")
        let before = editor.rawSource

        // At the cell's first character: the space behind it is the pad.
        editor.setSelectedRange(NSRange(location: text.location, length: 0))
        #expect(editor.tableCellPadding(at: text.location - 1))
        editor.deleteBackward(nil)
        #expect(editor.rawSource == before)

        // One in from there is ordinary text and deletes as usual.
        editor.setSelectedRange(NSRange(location: text.location + 1, length: 0))
        editor.deleteBackward(nil)
        #expect(editor.rawSource != before)
        #expect(editor.rawSource.contains("| 21 | d |"))
    }

    @Test("Forward delete stops at a cell's text")
    func forwardDeleteKeepsThePadding() {
        let editor = loadEditor("Intro.\n\n| a | b |\n| --- | --- |\n| c21 | d |\n")
        let ns = editor.rawSource as NSString
        let text = ns.range(of: "c21")
        let before = editor.rawSource

        editor.setSelectedRange(NSRange(location: text.upperBound, length: 0))
        #expect(editor.tableCellPadding(at: text.upperBound))
        editor.deleteForward(nil)
        #expect(editor.rawSource == before)
    }

    /// Backspace and forward-delete were the obvious paths; ⌥⌫ (delete word)
    /// and ⌘⌫ (delete to line start) were not, and a table row is one line, so
    /// ⌘⌫ would have taken every pipe before the caret. All of them route
    /// through `shouldChangeText`, which is where the structure is guarded now.
    @Test("Word and line deletes cannot take a pipe")
    func wordAndLineDeletesSpareTheStructure() {
        for action in [#selector(NSTextView.deleteWordBackward(_:)),
                       #selector(NSTextView.deleteWordForward(_:)),
                       #selector(NSTextView.deleteToBeginningOfLine(_:)),
                       #selector(NSTextView.deleteToEndOfLine(_:))] {
            let editor = loadEditor("Intro.\n\n| aa | bb |\n| --- | --- |\n| c21 | d22 |\n")
            let ns = editor.rawSource as NSString
            let before = editor.rawSource
            // Caret in the middle of a body cell, where a word/line delete would
            // otherwise run past the cell into the delimiters.
            let mid = ns.range(of: "c21").location + 1
            editor.setSelectedRange(NSRange(location: mid, length: 0))
            editor.perform(action, with: nil)
            #expect(editor.rawSource.components(separatedBy: "|").count
                    == before.components(separatedBy: "|").count,
                    "\(action) changed the pipe count")
        }
    }

    /// Selecting across a pipe and deleting — or typing over the selection —
    /// would merge two cells. The structural characters are protected whatever
    /// the replacement is.
    @Test("A delete or type-over spanning a pipe is refused")
    func editAcrossAPipeIsRefused() {
        let editor = loadEditor("Intro.\n\n| aa | bb |\n| --- | --- |\n| c21 | d22 |\n")
        let ns = editor.rawSource as NSString
        let from = ns.range(of: "c21").location + 1     // inside c21
        let to = ns.range(of: "d22").location + 1       // inside d22, across the pipe
        let before = editor.rawSource
        editor.setSelectedRange(NSRange(location: from, length: to - from))
        editor.deleteBackward(nil)
        #expect(editor.rawSource == before, "a cross-pipe delete went through")
        editor.setSelectedRange(NSRange(location: from, length: to - from))
        editor.insertText("x", replacementRange: editor.selectedRange())
        #expect(editor.rawSource == before, "a cross-pipe type-over went through")
    }

    /// The escaped pipe in a cell is content, and deletes like any character.
    @Test("An escaped pipe in a cell still deletes")
    func escapedPipeDeletes() {
        let editor = loadEditor("Intro.\n\n| a | b |\n| --- | --- |\n| x\\|y | d |\n")
        let ns = editor.rawSource as NSString
        let esc = ns.range(of: "\\|")   // the two-character escaped pipe
        // Backspace with the caret just after the escaped pipe removes only the
        // pipe — it is content, not a delimiter — leaving the backslash behind.
        editor.setSelectedRange(NSRange(location: esc.upperBound, length: 0))
        editor.deleteBackward(nil)
        #expect(editor.rawSource.contains("| x\\y | d |"))
    }

    /// Outside a table the same characters are ordinary text.
    @Test("A space beside a pipe in prose is not padding")
    func proseIsNotPadding() {
        let editor = loadEditor("a | b\n")
        let ns = editor.rawSource as NSString
        #expect(!editor.tableCellPadding(at: ns.range(of: "|").location - 1))
    }
}
