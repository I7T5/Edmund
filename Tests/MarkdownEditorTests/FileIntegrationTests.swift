import Testing
import AppKit
import Foundation
@testable import MarkdownEditorCore

// These tests exercise the exact same data path as Document:
//
//   File Open:  file → Data → String(data:encoding:) → editor.loadContent()
//   File Save:  editor.rawSource → Data(using: .utf8) → file
//
// Document.read(from:ofType:) and Document.data(ofType:) do nothing more
// than the above, so these tests cover the real I/O contract.

// MARK: - File I/O Helpers

/// Simulates Document.read(from:ofType:) → showWindows() pipeline.
/// Reads a file from disk, decodes as UTF-8, and loads into the editor.
@MainActor
private func openFile(_ url: URL, into editor: EditorTextView) throws {
    let data = try Data(contentsOf: url)
    guard let content = String(data: data, encoding: .utf8) else {
        throw NSError(domain: "TestError", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "Not valid UTF-8"])
    }
    editor.loadContent(content)
}

/// Simulates Document.data(ofType:) pipeline.
/// Encodes rawSource as UTF-8 and writes to a file.
@MainActor
private func saveFile(_ url: URL, from editor: EditorTextView) throws {
    guard let data = editor.rawSource.data(using: .utf8) else {
        throw NSError(domain: "TestError", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "Could not encode as UTF-8"])
    }
    try data.write(to: url)
}

/// Creates a temporary .md file with the given content and returns its URL.
private func makeTempFile(content: String, ext: String = "md") throws -> URL {
    let dir = FileManager.default.temporaryDirectory
    let name = UUID().uuidString + "." + ext
    let url = dir.appendingPathComponent(name)
    try content.data(using: .utf8)!.write(to: url)
    return url
}

/// Removes a file at the given URL (best-effort, no-throw).
private func removeTempFile(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

// ============================================================================
// MARK: - File Open
// ============================================================================

@Suite("Integration — File Open")
struct FileOpenTests {

    @Test("Open plain text file loads content into editor")
    @MainActor func openPlainText() throws {
        let url = try makeTempFile(content: "Hello, world!")
        defer { removeTempFile(url) }

        let editor = makeEditor()
        try openFile(url, into: editor)

        #expect(editor.rawSource == "Hello, world!")
        #expect(editor.blocks.count == 1)
        #expect(editor.blocks[0].content == "Hello, world!")
    }

    @Test("Open markdown file preserves all syntax")
    @MainActor func openMarkdownFile() throws {
        let md = "# Title\n\nSome **bold** and *italic* text.\n\n- item 1\n- item 2\n\n> a quote"
        let url = try makeTempFile(content: md)
        defer { removeTempFile(url) }

        let editor = makeEditor()
        try openFile(url, into: editor)

        #expect(editor.rawSource == md)
        #expect(editor.blocks.count == 8)  // each line is a block
        #expect(editor.blocks[0].content == "# Title")
        #expect(editor.blocks[2].content == "Some **bold** and *italic* text.")
        #expect(editor.blocks[4].content == "- item 1")
    }

    @Test("Open empty file creates one empty block")
    @MainActor func openEmptyFile() throws {
        let url = try makeTempFile(content: "")
        defer { removeTempFile(url) }

        let editor = makeEditor()
        try openFile(url, into: editor)

        #expect(editor.rawSource == "")
        #expect(editor.blocks.count == 1)
        #expect(editor.blocks[0].content == "")
    }

    @Test("Open file with only newlines creates correct number of blocks")
    @MainActor func openNewlinesOnly() throws {
        let url = try makeTempFile(content: "\n\n\n")
        defer { removeTempFile(url) }

        let editor = makeEditor()
        try openFile(url, into: editor)

        #expect(editor.rawSource == "\n\n\n")
        #expect(editor.blocks.count == 4)  // 3 newlines → 4 blocks
    }

    @Test("Open file with Unicode content preserves characters")
    @MainActor func openUnicodeFile() throws {
        let content = "Héllo wörld 🌍\nEmoji: 🎉🚀\nChinese: 你好世界"
        let url = try makeTempFile(content: content)
        defer { removeTempFile(url) }

        let editor = makeEditor()
        try openFile(url, into: editor)

        #expect(editor.rawSource == content)
        #expect(editor.blocks.count == 3)
    }

    @Test("Open .txt file works same as .md")
    @MainActor func openTxtFile() throws {
        let url = try makeTempFile(content: "plain text file", ext: "txt")
        defer { removeTempFile(url) }

        let editor = makeEditor()
        try openFile(url, into: editor)

        #expect(editor.rawSource == "plain text file")
    }

    @Test("Open file clears undo/redo stacks")
    @MainActor func openClearsUndo() throws {
        let url = try makeTempFile(content: "file content")
        defer { removeTempFile(url) }

        let editor = makeEditor()
        type("some typing", into: editor)  // creates undo history
        #expect(!editor.undoStack.isEmpty)

        try openFile(url, into: editor)

        #expect(editor.undoStack.isEmpty)
        #expect(editor.redoStack.isEmpty)
        #expect(editor.rawSource == "file content")
    }
}

// ============================================================================
// MARK: - File Save
// ============================================================================

@Suite("Integration — File Save")
struct FileSaveTests {

    @Test("Save writes rawSource to disk as UTF-8")
    @MainActor func saveBasic() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".md")
        defer { removeTempFile(url) }

        let editor = makeEditor()
        editor.loadContent("Hello, world!")

        try saveFile(url, from: editor)

        let saved = try String(contentsOf: url, encoding: .utf8)
        #expect(saved == "Hello, world!")
    }

    @Test("Save preserves markdown syntax exactly")
    @MainActor func savePreservesMarkdown() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".md")
        defer { removeTempFile(url) }

        let md = "# Title\n\n**bold** *italic* `code`\n\n- list\n\n> quote"
        let editor = makeEditor()
        editor.loadContent(md)

        try saveFile(url, from: editor)

        let saved = try String(contentsOf: url, encoding: .utf8)
        #expect(saved == md)
    }

    @Test("Save after editing writes modified content")
    @MainActor func saveAfterEditing() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".md")
        defer { removeTempFile(url) }

        let editor = makeEditor()
        editor.loadContent("original")
        type(" modified", into: editor)

        try saveFile(url, from: editor)

        let saved = try String(contentsOf: url, encoding: .utf8)
        #expect(saved.contains("modified"))
    }

    @Test("Save preserves Unicode content")
    @MainActor func saveUnicode() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".md")
        defer { removeTempFile(url) }

        let content = "Emoji: 🎉🚀\n你好世界\nCafé"
        let editor = makeEditor()
        editor.loadContent(content)

        try saveFile(url, from: editor)

        let saved = try String(contentsOf: url, encoding: .utf8)
        #expect(saved == content)
    }

    @Test("Save empty document writes empty file")
    @MainActor func saveEmpty() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".md")
        defer { removeTempFile(url) }

        let editor = makeEditor()
        // Editor starts with empty content

        try saveFile(url, from: editor)

        let saved = try String(contentsOf: url, encoding: .utf8)
        #expect(saved == "")
    }

    @Test("Save overwrites existing file content")
    @MainActor func saveOverwrites() throws {
        let url = try makeTempFile(content: "old content")
        defer { removeTempFile(url) }

        let editor = makeEditor()
        editor.loadContent("new content")

        try saveFile(url, from: editor)

        let saved = try String(contentsOf: url, encoding: .utf8)
        #expect(saved == "new content")
    }
}

// ============================================================================
// MARK: - Open → Edit → Save Round-Trip
// ============================================================================

@Suite("Integration — File Round-Trip")
struct FileRoundTripTests {

    @Test("Open file, edit, save, reopen — content matches")
    @MainActor func openEditSaveReopen() throws {
        let url = try makeTempFile(content: "Hello\n\nWorld")
        defer { removeTempFile(url) }

        // Open
        let editor = makeEditor()
        try openFile(url, into: editor)
        #expect(editor.rawSource == "Hello\n\nWorld")

        // Edit: cursor starts at block 0 position 0. Type at start.
        type("# ", into: editor)
        #expect(editor.rawSource.hasPrefix("# Hello"))

        // Save
        try saveFile(url, from: editor)

        // Reopen in a fresh editor
        let editor2 = makeEditor()
        try openFile(url, into: editor2)
        #expect(editor2.rawSource == "# Hello\n\nWorld")
    }

    @Test("Open markdown, edit inline formatting, save preserves syntax")
    @MainActor func editFormattingSave() throws {
        let url = try makeTempFile(content: "plain text")
        defer { removeTempFile(url) }

        let editor = makeEditor()
        try openFile(url, into: editor)

        // Cursor at 0 in active block. Move to end of block and type.
        let blockLen = (editor.blocks[0].content as NSString).length
        editor.setSelectedRange(NSRange(location: blockLen, length: 0))
        type(" **bold** and *italic*", into: editor)

        try saveFile(url, from: editor)

        let saved = try String(contentsOf: url, encoding: .utf8)
        #expect(saved.contains("**bold**"))
        #expect(saved.contains("*italic*"))
    }

    @Test("Multiple save cycles preserve content integrity")
    @MainActor func multipleSaveCycles() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".md")
        defer { removeTempFile(url) }

        let editor = makeEditor()

        // Cycle 1: type and save
        type("line1", into: editor)
        try saveFile(url, from: editor)

        var saved = try String(contentsOf: url, encoding: .utf8)
        #expect(saved == "line1")

        // Cycle 2: add line and save
        pressEnter(in: editor)
        type("line2", into: editor)
        try saveFile(url, from: editor)

        saved = try String(contentsOf: url, encoding: .utf8)
        #expect(saved == "line1\nline2")

        // Cycle 3: add more and save
        pressEnter(in: editor)
        type("line3", into: editor)
        try saveFile(url, from: editor)

        saved = try String(contentsOf: url, encoding: .utf8)
        #expect(saved == "line1\nline2\nline3")
    }

    @Test("Open file, undo all edits, save restores original")
    @MainActor func undoAllAndSave() throws {
        let original = "Title\n\nBody text"
        let url = try makeTempFile(content: original)
        defer { removeTempFile(url) }

        let editor = makeEditor()
        try openFile(url, into: editor)

        // Edit: cursor is at start of block 0 (active). Type at cursor.
        type("extra ", into: editor)
        #expect(editor.rawSource != original)

        // Undo the edit
        editor.undo(nil)
        #expect(editor.rawSource == original)

        // Save
        try saveFile(url, from: editor)

        let saved = try String(contentsOf: url, encoding: .utf8)
        #expect(saved == original)
    }

    @Test("Open file A, open file B in same editor replaces content")
    @MainActor func openSecondFileReplacesFirst() throws {
        let urlA = try makeTempFile(content: "File A content")
        let urlB = try makeTempFile(content: "File B content")
        defer { removeTempFile(urlA); removeTempFile(urlB) }

        let editor = makeEditor()

        try openFile(urlA, into: editor)
        #expect(editor.rawSource == "File A content")

        try openFile(urlB, into: editor)
        #expect(editor.rawSource == "File B content")
        #expect(editor.blocks.count == 1)
        #expect(editor.blocks[0].content == "File B content")
    }
}

// ============================================================================
// MARK: - File Content Edge Cases
// ============================================================================

@Suite("Integration — File Edge Cases")
struct FileEdgeCaseTests {

    @Test("File with trailing newline preserves it through round-trip")
    @MainActor func trailingNewline() throws {
        let content = "line1\nline2\n"
        let url = try makeTempFile(content: content)
        defer { removeTempFile(url) }

        let editor = makeEditor()
        try openFile(url, into: editor)
        #expect(editor.rawSource == content)

        let saveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".md")
        defer { removeTempFile(saveURL) }

        try saveFile(saveURL, from: editor)
        let saved = try String(contentsOf: saveURL, encoding: .utf8)
        #expect(saved == content)
    }

    @Test("Large file loads correctly")
    @MainActor func largeFile() throws {
        // 1000 lines of markdown
        var lines: [String] = []
        for i in 0..<1000 {
            lines.append("Line \(i): some **bold** and *italic* text here.")
        }
        let content = lines.joined(separator: "\n")
        let url = try makeTempFile(content: content)
        defer { removeTempFile(url) }

        let editor = makeEditor()
        try openFile(url, into: editor)

        #expect(editor.blocks.count == 1000)
        #expect(editor.rawSource == content)
    }

    @Test("File with mixed line content round-trips correctly")
    @MainActor func mixedContentRoundTrip() throws {
        let content = """
        # Heading

        Regular paragraph with **bold**, *italic*, and `code`.

        - [ ] todo unchecked
        - [x] todo checked
        - bullet

        1. first
        2. second

        > blockquote

        ~~strikethrough~~ and ==highlight==

        [link](https://example.com)
        """
        let url = try makeTempFile(content: content)
        defer { removeTempFile(url) }

        let editor = makeEditor()
        try openFile(url, into: editor)
        #expect(editor.rawSource == content)

        // Save to a new file
        let saveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".md")
        defer { removeTempFile(saveURL) }

        try saveFile(saveURL, from: editor)
        let saved = try String(contentsOf: saveURL, encoding: .utf8)
        #expect(saved == content)
    }

    @Test("File with special characters round-trips correctly")
    @MainActor func specialCharacters() throws {
        let content = "Tabs:\t\there\nBackslash: \\\nQuotes: \"double\" 'single'\nAngle: <tag>"
        let url = try makeTempFile(content: content)
        defer { removeTempFile(url) }

        let editor = makeEditor()
        try openFile(url, into: editor)

        let saveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".md")
        defer { removeTempFile(saveURL) }

        try saveFile(saveURL, from: editor)
        let saved = try String(contentsOf: saveURL, encoding: .utf8)
        #expect(saved == content)
    }
}
