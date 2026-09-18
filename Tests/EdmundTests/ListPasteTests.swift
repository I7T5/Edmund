import Testing
import AppKit
@testable import EdmundCore

/// Pasting list text into a list item rewrites the pasted markers to the
/// target list's family and re-indents them relative to the target item.
@Suite("List-aware paste")
@MainActor
struct ListPasteTests {

    @Test("A bulleted list pasted into a checklist becomes checklist items")
    func bulletsIntoChecklist() {
        let out = ListPaste.adjust("- one\n- two", targetLine: "- [ ] ", caretInLine: 6)
        #expect(out == "one\n- [ ] two")
    }

    @Test("A checklist pasted into a bulleted list drops the boxes")
    func checklistIntoBullets() {
        let out = ListPaste.adjust("- [ ] one\n- [x] two", targetLine: "* ", caretInLine: 2)
        #expect(out == "one\n* two")
    }

    @Test("A pasted tick survives into a checklist")
    func tickKept() {
        let out = ListPaste.adjust("- [x] done\n- todo", targetLine: "- [ ] ", caretInLine: 6)
        #expect(out == "done\n- [ ] todo")
    }

    @Test("Into a numbered list every item becomes `1.` for renumbering")
    func intoOrdered() {
        let out = ListPaste.adjust("- a\n- b", targetLine: "3. ", caretInLine: 3)
        #expect(out == "a\n1. b")
    }

    @Test("Nesting is kept relative to the first pasted item, under the target's indent")
    func relativeNesting() {
        let out = ListPaste.adjust("  - a\n    - b\n  - c", targetLine: "    - ", caretInLine: 6)
        #expect(out == "a\n      - b\n    - c")
    }

    @Test("Pasted after an item's content, the items start on a new line")
    func afterContentStartsBelow() {
        let out = ListPaste.adjust("- a\n- b", targetLine: "- first", caretInLine: 7)
        #expect(out == "\n- a\n- b")
    }

    @Test("Lines that are not list items pass through unchanged")
    func continuationLinesUntouched() {
        let out = ListPaste.adjust("- a\n  more\n- b", targetLine: "- ", caretInLine: 2)
        #expect(out == "a\n  more\n- b")
    }

    @Test("Nothing happens unless both sides are lists")
    func ordinaryPasteOtherwise() {
        #expect(ListPaste.adjust("- a", targetLine: "plain", caretInLine: 5) == nil)
        #expect(ListPaste.adjust("plain", targetLine: "- ", caretInLine: 2) == nil)
    }

    /// The path `paste(_:)` takes: a private pasteboard (the general one is
    /// the maintainer's clipboard), the caret's block, and the renumbering
    /// that follows an ordinary edit.
    @Test("Pasting into a numbered item renumbers the pasted run")
    func pasteEndToEnd() {
        let editor = makeEditor()
        editor.loadContent("1. one\n2. ")
        editor.setSelectedRange(NSRange(location: 10, length: 0))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ListPasteTests"))
        pasteboard.clearContents()
        pasteboard.setString("- two\n- three", forType: .string)
        let adjusted = editor.listAdjustedPasteText(from: pasteboard)
        #expect(adjusted == "two\n1. three")
        editor.insertText(adjusted ?? "", replacementRange: editor.selectedRange())
        #expect(editor.rawSource == "1. one\n2. two\n3. three")
    }
}
