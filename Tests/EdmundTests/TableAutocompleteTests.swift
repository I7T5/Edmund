import Testing
import AppKit
@testable import EdmundCore

/// Once a table is a header and its separator, Return on the separator line
/// finishes it: the separator's dash runs are padded to the header columns'
/// widths and an empty body row is added to type into. Return from the header
/// row (a body row insert) is covered in TableInlineEditingTests; this covers
/// the separator-line gap, where the caret is in no cell.

@Suite("Table autocomplete")
@MainActor
struct TableAutocompleteTests {

    private func loadEditor(_ text: String) -> EditorTextView {
        let editor = makeEditor()
        editor.updateContentInset()
        editor.loadContent(text)
        ensureFullLayout(editor)
        layOutViewport(editor)
        return editor
    }

    /// Caret on the separator line of `header | separator`: the separator is
    /// padded to the header widths, a body row appears, and the caret lands in
    /// its first cell.
    @Test("Return on the separator pads it and adds a body row")
    func finishesTheTable() {
        let doc = "Lead.\n\n| Name | Age |\n| - | - |\n"
        let editor = loadEditor(doc)
        let sep = (doc as NSString).range(of: "| - | - |")
        editor.setSelectedRange(NSRange(location: sep.location, length: 0))
        editor.insertNewline(nil)
        // "Name" is 4 wide, "Age" is 3 — the dashes match.
        #expect(editor.rawSource.contains("| Name | Age |\n| ---- | --- |\n|  |  |"))
        // The caret is in the new body row's first cell.
        let ns = editor.rawSource as NSString
        let line = ns.lineRange(for: editor.selectedRange())
        #expect(ns.substring(with: line).trimmingCharacters(in: .newlines) == "|  |  |")
        #expect(editor.selectedRange().location == line.location + 2)   // one space in
    }

    /// A short header still yields a valid GFM run — three dashes, not one.
    @Test("A header narrower than three keeps three dashes")
    func flooredAtThree() {
        let doc = "| a | bb |\n| - | - |\n"
        let editor = loadEditor(doc)
        let sep = (doc as NSString).range(of: "| - | - |")
        editor.setSelectedRange(NSRange(location: sep.location, length: 0))
        editor.insertNewline(nil)
        #expect(editor.rawSource.contains("| a | bb |\n| --- | --- |\n"))
    }

    /// Alignment markers survive the padding: `:-` stays left-anchored, `-:`
    /// right, `:-:` centred — only the dash run between them grows.
    @Test("Alignment colons are kept")
    func keepsAlignment() {
        let doc = "| Left | Mid | Right |\n| :- | :-: | -: |\n"
        let editor = loadEditor(doc)
        let sep = (doc as NSString).range(of: "| :- | :-: | -: |")
        editor.setSelectedRange(NSRange(location: sep.location, length: 0))
        editor.insertNewline(nil)
        // Left=4 → `:---`, Mid=3 → `:-:`, Right=5 → `----:`.
        #expect(editor.rawSource.contains("| :--- | :-: | ----: |"))
    }

    /// A table written without outer pipes must not gain them here either.
    @Test("A pipe-less table stays pipe-less")
    func staysPipeless() {
        let doc = "a | b\n- | -\n"
        let editor = loadEditor(doc)
        let sep = (doc as NSString).range(of: "- | -")
        editor.setSelectedRange(NSRange(location: sep.location, length: 0))
        editor.insertNewline(nil)
        #expect(editor.rawSource.contains("a | b\n--- | ---\n  |  "))
        #expect(!editor.rawSource.contains("|  |  |"))
    }

    /// Only a body-less table autocompletes. With a body row already present,
    /// the separator handler stands down and Return does its ordinary thing.
    @Test("A table that already has a body does not autocomplete")
    func skipsAnEstablishedTable() {
        let doc = "| a | b |\n| --- | --- |\n| c | d |\n"
        let editor = loadEditor(doc)
        let sep = (doc as NSString).range(of: "| --- | --- |")
        editor.setSelectedRange(NSRange(location: sep.location, length: 0))
        #expect(editor.handleTableSeparatorNewline() == false)
    }

    /// One undo restores the original two-line table.
    @Test("Undo restores the header and separator")
    func undoRestores() {
        let doc = "| Name | Age |\n| - | - |\n"
        let editor = loadEditor(doc)
        let sep = (doc as NSString).range(of: "| - | - |")
        editor.setSelectedRange(NSRange(location: sep.location, length: 0))
        let before = editor.rawSource
        editor.insertNewline(nil)
        #expect(editor.rawSource != before)
        editor.undo(nil)
        #expect(editor.rawSource == before)
    }
}
