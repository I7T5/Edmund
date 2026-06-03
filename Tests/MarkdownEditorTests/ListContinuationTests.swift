import Testing
import AppKit
@testable import MarkdownEditorCore

// MARK: - List Continuation on Enter

@Suite("EditorTextView — List Continuation")
struct ListContinuationTests {

    // MARK: - Unordered Lists

    @Test("Enter after bullet item inserts new bullet")
    @MainActor func enterAfterBullet() {
        let editor = makeEditor()
        editor.loadContent("- hello")
        // Place cursor at end
        editor.setSelectedRange(NSRange(location: 7, length: 0))
        editor.insertNewline(nil)
        #expect(editor.rawSource == "- hello\n- ")
    }

    @Test("Enter after * bullet inserts new * bullet")
    @MainActor func enterAfterStarBullet() {
        let editor = makeEditor()
        editor.loadContent("* hello")
        editor.setSelectedRange(NSRange(location: 7, length: 0))
        editor.insertNewline(nil)
        #expect(editor.rawSource == "* hello\n* ")
    }

    @Test("Enter on empty bullet line removes marker")
    @MainActor func enterOnEmptyBullet() {
        let editor = makeEditor()
        editor.loadContent("- hello\n- ")
        // Cursor at end of "- " (offset 10)
        editor.setSelectedRange(NSRange(location: 10, length: 0))
        editor.insertNewline(nil)
        #expect(editor.rawSource == "- hello\n")
    }

    @Test("Enter preserves indentation level")
    @MainActor func enterPreservesIndent() {
        let editor = makeEditor()
        editor.loadContent("  - nested")
        editor.setSelectedRange(NSRange(location: 10, length: 0))
        editor.insertNewline(nil)
        #expect(editor.rawSource == "  - nested\n  - ")
    }

    // MARK: - Ordered Lists

    @Test("Enter after ordered item increments number")
    @MainActor func enterAfterOrdered() {
        let editor = makeEditor()
        editor.loadContent("1. first")
        editor.setSelectedRange(NSRange(location: 8, length: 0))
        editor.insertNewline(nil)
        #expect(editor.rawSource == "1. first\n2. ")
    }

    @Test("Enter on empty ordered line removes marker")
    @MainActor func enterOnEmptyOrdered() {
        let editor = makeEditor()
        editor.loadContent("1. first\n2. ")
        editor.setSelectedRange(NSRange(location: 12, length: 0))
        editor.insertNewline(nil)
        #expect(editor.rawSource == "1. first\n")
    }

    // MARK: - Checkbox Lists

    @Test("Enter after unchecked todo inserts new unchecked todo")
    @MainActor func enterAfterUncheckedTodo() {
        let editor = makeEditor()
        editor.loadContent("- [ ] task")
        editor.setSelectedRange(NSRange(location: 10, length: 0))
        editor.insertNewline(nil)
        #expect(editor.rawSource == "- [ ] task\n- [ ] ")
    }

    @Test("Enter after checked todo inserts new unchecked todo")
    @MainActor func enterAfterCheckedTodo() {
        let editor = makeEditor()
        editor.loadContent("- [x] done")
        editor.setSelectedRange(NSRange(location: 10, length: 0))
        editor.insertNewline(nil)
        #expect(editor.rawSource == "- [x] done\n- [ ] ")
    }

    @Test("Enter on empty todo line removes marker")
    @MainActor func enterOnEmptyTodo() {
        let editor = makeEditor()
        editor.loadContent("- [ ] task\n- [ ] ")
        editor.setSelectedRange(NSRange(location: 17, length: 0))
        editor.insertNewline(nil)
        #expect(editor.rawSource == "- [ ] task\n")
    }

    // MARK: - Non-List Lines

    @Test("Enter on non-list line does normal newline")
    @MainActor func enterOnNonListLine() {
        let editor = makeEditor()
        editor.loadContent("hello")
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        editor.insertNewline(nil)
        #expect(editor.rawSource == "hello\n")
    }

    // MARK: - Mid-Line Enter

    @Test("Enter mid-line splits and continues list")
    @MainActor func enterMidLine() {
        let editor = makeEditor()
        editor.loadContent("- hello world")
        // Cursor after "hello" (offset 7)
        editor.setSelectedRange(NSRange(location: 7, length: 0))
        editor.insertNewline(nil)
        #expect(editor.rawSource == "- hello\n- world")
    }
}
