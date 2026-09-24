import Testing
@testable import EdmundCore

#if !DEBUG
@Suite("Undo history safety")
struct UndoSafetyTests {
    @Test(arguments: [false, true])
    @MainActor func invalidEntryKeepsDocumentAndDropsHistory(redo: Bool) {
        let editor = makeEditor()
        editor.loadContent("unsaved text")
        let bad = EditorTextView.UndoEntry(
            location: 100, laterLength: 1, earlierText: "x", cursorInRaw: 0)
        let other = EditorTextView.UndoEntry(
            location: 0, laterLength: 1, earlierText: "u", cursorInRaw: 0)
        editor.undoStack = [redo ? other : bad]
        editor.redoStack = [redo ? bad : other]

        if redo { editor.redo(nil) } else { editor.undo(nil) }

        #expect(editor.rawSource == "unsaved text")
        #expect(editor.textStorage?.string == "unsaved text")
        #expect(editor.undoStack.isEmpty)
        #expect(editor.redoStack.isEmpty)
    }
}
#endif
