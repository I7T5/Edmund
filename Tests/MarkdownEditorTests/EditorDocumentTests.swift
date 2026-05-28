import Testing
import AppKit
@testable import MarkdownEditorCore

// MARK: - Document Loading

@Suite("EditorTextView — Document Loading")
struct EditorDocumentLoadingTests {

    @Test("loadContent replaces editor content")
    @MainActor func loadContentReplacesContent() {
        let editor = makeEditor()
        type("old text", into: editor)
        #expect(editor.rawSource == "old text")

        editor.loadContent("new content")
        #expect(editor.rawSource == "new content")
        #expect(editor.blocks.count == 1)
        #expect(editor.blocks[0].content == "new content")
    }

    @Test("loadContent with multiple lines creates multiple blocks")
    @MainActor func loadContentMultipleBlocks() {
        let editor = makeEditor()
        editor.loadContent("line one\nline two\nline three")
        #expect(editor.rawSource == "line one\nline two\nline three")
        #expect(editor.blocks.count == 3)
        #expect(editor.blocks[0].content == "line one")
        #expect(editor.blocks[1].content == "line two")
        #expect(editor.blocks[2].content == "line three")
    }

    @Test("loadContent clears undo/redo stacks")
    @MainActor func loadContentClearsUndo() {
        let editor = makeEditor()
        type("some edits", into: editor)
        #expect(!editor.undoStack.isEmpty)

        editor.loadContent("fresh document")
        #expect(editor.undoStack.isEmpty)
        #expect(editor.redoStack.isEmpty)
    }

    @Test("loadContent with empty string produces one empty block")
    @MainActor func loadContentEmpty() {
        let editor = makeEditor()
        type("something", into: editor)

        editor.loadContent("")
        #expect(editor.rawSource == "")
        #expect(editor.blocks.count == 1)
        #expect(editor.blocks[0].content == "")
    }

    @Test("loadContent styles markdown in non-active blocks (text preserved, delimiters hidden)")
    @MainActor func loadContentRendersInactiveBlocks() {
        let editor = makeEditor()
        editor.loadContent("**bold**\n*italic*")
        #expect(editor.blocks.count == 2)

        // With word-level rendering, text storage always = rawSource.
        // Block 0 is active (cursor at 0), block 1 is non-active.
        let ts = editor.textStorage!.string
        #expect(ts.contains("**bold**"))   // active — raw
        #expect(ts.contains("*italic*"))   // non-active — raw text preserved

        // Non-active block's delimiters are hidden via attributes, not stripped.
        // "*" at block 1 start should have hidden font.
        let b1Start = editor.displayRanges[1].location
        let delimFont = font(at: b1Start, in: editor)!
        #expect(delimFont.pointSize < 1.0)
        #expect(fgColor(at: b1Start, in: editor) == NSColor.clear)
    }

    @Test("loadContent with markdown preserves rawSource exactly")
    @MainActor func loadContentPreservesRawSource() {
        let editor = makeEditor()
        let markdown = "# Heading\n\n**bold** and *italic*\n\n> quote\n\n- list item"
        editor.loadContent(markdown)
        #expect(editor.rawSource == markdown)
    }

    @Test("Typing after loadContent works normally")
    @MainActor func typingAfterLoadContent() {
        let editor = makeEditor()
        editor.loadContent("hello")
        // Cursor should be at position 0 after load
        type(" world", into: editor)
        #expect(editor.rawSource.contains("world"))
    }
}
