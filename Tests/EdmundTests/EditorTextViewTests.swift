import Testing
import AppKit
@testable import EdmundCore

// MARK: - Initialization

@Suite("EditorTextView — Initialization")
struct EditorInitTests {

    @Test("Starts with empty rawSource and one empty block")
    @MainActor func initialState() {
        let editor = makeEditor()
        #expect(editor.rawSource == "")
        #expect(editor.blocks.count == 1)
        #expect(editor.blocks[0].content == "")
        #expect(editor.activeBlockIndex == 0)
    }

    @Test("Text storage is empty after init")
    @MainActor func emptyTextStorage() {
        let editor = makeEditor()
        #expect(editor.textStorage?.string == "")
    }

    @Test("Undo and redo stacks are empty at start")
    @MainActor func emptyUndoStacks() {
        let editor = makeEditor()
        #expect(editor.undoStack.isEmpty)
        #expect(editor.redoStack.isEmpty)
    }
}

// MARK: - Basic Editing

@Suite("EditorTextView — Editing")
struct EditorEditTests {

    @Test("Typing updates rawSource")
    @MainActor func typingUpdatesRawSource() {
        let editor = makeEditor()
        type("hello", into: editor)
        #expect(editor.rawSource == "hello")
    }

    @Test("Typing updates text storage")
    @MainActor func typingUpdatesTextStorage() {
        let editor = makeEditor()
        type("hello", into: editor)
        #expect(editor.textStorage?.string == "hello")
    }

    @Test("Cursor advances to end of typed text")
    @MainActor func cursorAdvances() {
        let editor = makeEditor()
        type("hello", into: editor)
        #expect(editor.selectedRange().location == 5)
        #expect(editor.selectedRange().length == 0)
    }

    @Test("Paste inserts text at cursor")
    @MainActor func pasteInserts() {
        let editor = makeEditor()
        paste("hello world", into: editor)
        #expect(editor.rawSource == "hello world")
        #expect(editor.selectedRange().location == 11)
    }

    @Test("Backspace removes character before cursor")
    @MainActor func backspaceRemoves() {
        let editor = makeEditor()
        type("abc", into: editor)
        pressBackspace(in: editor)
        #expect(editor.rawSource == "ab")
    }

    @Test("Multiple backspaces")
    @MainActor func multipleBackspaces() {
        let editor = makeEditor()
        type("abc", into: editor)
        pressBackspace(in: editor)
        pressBackspace(in: editor)
        #expect(editor.rawSource == "a")
    }
}

// MARK: - Block Splitting

@Suite("EditorTextView — Block Splitting")
struct EditorBlockSplitTests {

    @Test("Enter creates a new block")
    @MainActor func enterCreatesBlock() {
        let editor = makeEditor()
        type("hello", into: editor)
        pressEnter(in: editor)
        #expect(editor.blocks.count == 2)
        #expect(editor.blocks[0].content == "hello")
        #expect(editor.blocks[1].content == "")
    }

    @Test("rawSource contains newline after Enter")
    @MainActor func rawSourceHasNewline() {
        let editor = makeEditor()
        type("hello", into: editor)
        pressEnter(in: editor)
        #expect(editor.rawSource == "hello\n")
    }

    @Test("Typing after Enter goes into the new block")
    @MainActor func typingAfterEnter() {
        let editor = makeEditor()
        type("hello", into: editor)
        pressEnter(in: editor)
        type("world", into: editor)
        #expect(editor.rawSource == "hello\nworld")
        #expect(editor.blocks.count == 2)
        #expect(editor.blocks[0].content == "hello")
        #expect(editor.blocks[1].content == "world")
    }

    @Test("Enter in the middle of text splits the block")
    @MainActor func enterInMiddle() {
        let editor = makeEditor()
        type("helloworld", into: editor)
        // Move cursor to position 5 (between "hello" and "world")
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        pressEnter(in: editor)
        #expect(editor.blocks.count == 2)
        #expect(editor.blocks[0].content == "hello")
        #expect(editor.blocks[1].content == "world")
    }

    @Test("Multiple Enters create multiple blocks")
    @MainActor func multipleEnters() {
        let editor = makeEditor()
        type("a", into: editor)
        pressEnter(in: editor)
        type("b", into: editor)
        pressEnter(in: editor)
        type("c", into: editor)
        #expect(editor.blocks.count == 3)
        #expect(editor.rawSource == "a\nb\nc")
    }
}

// MARK: - Integration

@Suite("EditorTextView — Integration")
struct EditorIntegrationTests {

    @Test("Full editing session: type, Enter, type, undo all, redo all")
    @MainActor func fullSession() {
        let editor = makeEditor()

        // Type first line
        type("hello", into: editor)
        #expect(editor.rawSource == "hello")

        // Press Enter
        pressEnter(in: editor)
        #expect(editor.blocks.count == 2)

        // Type second line
        type("world", into: editor)
        #expect(editor.rawSource == "hello\nworld")

        // Undo "world"
        editor.undo(nil)
        #expect(editor.rawSource == "hello\n")

        // Undo Enter
        editor.undo(nil)
        #expect(editor.rawSource == "hello")
        #expect(editor.blocks.count == 1)

        // Undo "hello"
        editor.undo(nil)
        #expect(editor.rawSource == "")

        // Redo everything
        editor.redo(nil)
        #expect(editor.rawSource == "hello")
        editor.redo(nil)
        #expect(editor.rawSource == "hello\n")
        editor.redo(nil)
        #expect(editor.rawSource == "hello\nworld")
    }

    @Test("Backspace at start of line merges with previous block")
    @MainActor func backspaceMergesBlocks() {
        let editor = makeEditor()
        type("hello", into: editor)
        pressEnter(in: editor)
        type("world", into: editor)
        #expect(editor.blocks.count == 2)

        // Move cursor to start of "world" and backspace
        // After Enter+typing, cursor is at end of "world".
        // "hello\nworld" in display. Position 6 = start of "world" block.
        editor.setSelectedRange(NSRange(location: 6, length: 0))
        pressBackspace(in: editor)
        // This should delete the \n, merging into "helloworld"
        #expect(editor.rawSource == "helloworld")
        #expect(editor.blocks.count == 1)
    }
}
