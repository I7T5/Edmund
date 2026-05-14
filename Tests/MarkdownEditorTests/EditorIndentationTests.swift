import Testing
import AppKit
@testable import MarkdownEditorCore

// MARK: - Tab / Shift-Tab List Indentation

@Suite("EditorTextView — List Indentation")
struct EditorTextViewListIndentationTests {

    // MARK: - isListLine Detection

    @Test("isListLine detects unordered list markers")
    @MainActor func isListLineUnordered() {
        let editor = makeEditor()
        #expect(editor.isListLine("- item"))
        #expect(editor.isListLine("* item"))
        #expect(editor.isListLine("+ item"))
        #expect(editor.isListLine("  - nested"))
        #expect(editor.isListLine("    - deeply nested"))
    }

    @Test("isListLine detects ordered list markers")
    @MainActor func isListLineOrdered() {
        let editor = makeEditor()
        #expect(editor.isListLine("1. item"))
        #expect(editor.isListLine("99. item"))
        #expect(editor.isListLine("  1. nested"))
    }

    @Test("isListLine rejects non-list lines")
    @MainActor func isListLineRejectsNonList() {
        let editor = makeEditor()
        #expect(!editor.isListLine("hello"))
        #expect(!editor.isListLine("# heading"))
        #expect(!editor.isListLine("> quote"))
        #expect(!editor.isListLine(""))
        #expect(!editor.isListLine("-no space"))
    }

    // MARK: - Tab Indent

    @Test("Tab on single list line adds 4 spaces")
    @MainActor func tabIndentsSingleLine() {
        let editor = makeEditor()
        editor.loadContent("- item")
        // Place cursor somewhere in the line
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        editor.insertTab(nil)
        #expect(editor.rawSource == "    - item")
    }

    @Test("Tab on ordered list line adds 4 spaces")
    @MainActor func tabIndentsOrderedList() {
        let editor = makeEditor()
        editor.loadContent("1. item")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertTab(nil)
        #expect(editor.rawSource == "    1. item")
    }

    @Test("Tab on non-list line inserts tab character")
    @MainActor func tabOnNonListInsertsTabs() {
        let editor = makeEditor()
        editor.loadContent("hello")
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        editor.insertTab(nil)
        #expect(editor.rawSource.contains("\t"))
    }

    @Test("Tab indents multiple selected list lines")
    @MainActor func tabIndentsMultipleLines() {
        let editor = makeEditor()
        editor.loadContent("- a\n- b\n- c")
        // Select across all three blocks (in display, active block 0 shows raw)
        let len = editor.textStorage!.length
        editor.setSelectedRange(NSRange(location: 0, length: len))
        editor.insertTab(nil)
        #expect(editor.rawSource == "    - a\n    - b\n    - c")
    }

    @Test("Tab stacks indentation on repeated use")
    @MainActor func tabStacksIndent() {
        let editor = makeEditor()
        editor.loadContent("- item")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertTab(nil)
        editor.insertTab(nil)
        #expect(editor.rawSource == "        - item")
    }

    @Test("Tab on mixed list and non-list falls through to default")
    @MainActor func tabMixedListNonList() {
        let editor = makeEditor()
        editor.loadContent("- a\nhello\n- c")
        let len = editor.textStorage!.length
        editor.setSelectedRange(NSRange(location: 0, length: len))
        editor.insertTab(nil)
        // Should NOT have indented; default behavior inserts a tab
        #expect(!editor.rawSource.hasPrefix("    - a"))
    }

    // MARK: - Shift-Tab Dedent

    @Test("Shift-Tab removes up to 4 leading spaces")
    @MainActor func shiftTabRemovesSpaces() {
        let editor = makeEditor()
        editor.loadContent("    - item")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertBacktab(nil)
        #expect(editor.rawSource == "- item")
    }

    @Test("Shift-Tab removes partial indent (fewer than 4 spaces)")
    @MainActor func shiftTabRemovesPartialIndent() {
        let editor = makeEditor()
        editor.loadContent("  - item")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertBacktab(nil)
        #expect(editor.rawSource == "- item")
    }

    @Test("Shift-Tab on root-level list with no spaces does nothing")
    @MainActor func shiftTabRootLevelNoOp() {
        let editor = makeEditor()
        editor.loadContent("- item")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertBacktab(nil)
        #expect(editor.rawSource == "- item")
    }

    @Test("Shift-Tab dedents multiple selected lines")
    @MainActor func shiftTabDedentsMultipleLines() {
        let editor = makeEditor()
        editor.loadContent("    - a\n    - b\n    - c")
        let len = editor.textStorage!.length
        editor.setSelectedRange(NSRange(location: 0, length: len))
        editor.insertBacktab(nil)
        #expect(editor.rawSource == "- a\n- b\n- c")
    }

    @Test("Shift-Tab with mixed indent levels removes up to 4 from each")
    @MainActor func shiftTabMixedIndentLevels() {
        let editor = makeEditor()
        editor.loadContent("        - a\n    - b\n  - c")
        let len = editor.textStorage!.length
        editor.setSelectedRange(NSRange(location: 0, length: len))
        editor.insertBacktab(nil)
        #expect(editor.rawSource == "    - a\n- b\n- c")
    }

    // MARK: - Undo Integration

    @Test("Undo reverts tab indent")
    @MainActor func undoRevertsIndent() {
        let editor = makeEditor()
        editor.loadContent("- item")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertTab(nil)
        #expect(editor.rawSource == "    - item")
        editor.undo(nil)
        #expect(editor.rawSource == "- item")
    }

    @Test("Undo reverts shift-tab dedent")
    @MainActor func undoRevertsDedent() {
        let editor = makeEditor()
        editor.loadContent("    - item")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertBacktab(nil)
        #expect(editor.rawSource == "- item")
        editor.undo(nil)
        #expect(editor.rawSource == "    - item")
    }

    @Test("Tab then Shift-Tab roundtrips")
    @MainActor func tabShiftTabRoundtrip() {
        let editor = makeEditor()
        editor.loadContent("- item")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertTab(nil)
        #expect(editor.rawSource == "    - item")
        editor.insertBacktab(nil)
        #expect(editor.rawSource == "- item")
    }
}

// MARK: - List Indentation Integration

@Suite("EditorTextView — List Indent Integration")
struct EditorListIndentIntegrationTests {

    @Test("Type a list from scratch, indent it, verify display")
    @MainActor func typeListThenIndent() {
        let editor = makeEditor()

        // Type a list item from scratch
        type("- apples", into: editor)
        #expect(editor.rawSource == "- apples")
        #expect(editor.blocks.count == 1)

        // Press Enter and type another item
        pressEnter(in: editor)
        type("- bananas", into: editor)
        #expect(editor.rawSource == "- apples\n- bananas")
        #expect(editor.blocks.count == 2)

        // Indent the second line (cursor is already there)
        editor.insertTab(nil)
        #expect(editor.rawSource == "- apples\n    - bananas")
        #expect(editor.blocks[1].content == "    - bananas")

        // Verify text storage contains the indented text
        let display = editor.textStorage!.string
        #expect(display.contains("    - bananas"))
    }

    @Test("Type mixed list, select all, indent, verify all indented")
    @MainActor func selectAllAndIndent() {
        let editor = makeEditor()

        type("- first", into: editor)
        pressEnter(in: editor)
        type("- second", into: editor)
        pressEnter(in: editor)
        type("- third", into: editor)
        #expect(editor.blocks.count == 3)

        // Select all and indent
        let len = editor.textStorage!.length
        editor.setSelectedRange(NSRange(location: 0, length: len))
        editor.insertTab(nil)

        #expect(editor.rawSource == "    - first\n    - second\n    - third")

        // Verify each block was indented
        for block in editor.blocks {
            #expect(block.content.hasPrefix("    - "))
        }
    }

    @Test("Indent then dedent restores original via display pipeline")
    @MainActor func indentDedentFullPipeline() {
        let editor = makeEditor()

        type("1. buy milk", into: editor)
        pressEnter(in: editor)
        type("2. buy eggs", into: editor)

        let original = editor.rawSource

        // Select all and indent
        let len = editor.textStorage!.length
        editor.setSelectedRange(NSRange(location: 0, length: len))
        editor.insertTab(nil)
        #expect(editor.rawSource != original)

        // Select all again and dedent
        let newLen = editor.textStorage!.length
        editor.setSelectedRange(NSRange(location: 0, length: newLen))
        editor.insertBacktab(nil)
        #expect(editor.rawSource == original)
    }

    @Test("Cursor position preserved after indent on single line")
    @MainActor func cursorPositionAfterIndent() {
        let editor = makeEditor()
        editor.loadContent("- hello")

        // Place cursor after "hel" → raw offset 4 ("- he|llo")
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        editor.insertTab(nil)

        // rawSource should be "    - hello", cursor should be at offset 8
        #expect(editor.rawSource == "    - hello")
        let sel = editor.selectedRange()
        // Cursor shifted by 4 (the indent)
        #expect(sel.location == 8)
        #expect(sel.length == 0)
    }

    @Test("Cursor position preserved after dedent on single line")
    @MainActor func cursorPositionAfterDedent() {
        let editor = makeEditor()
        editor.loadContent("    - hello")

        // Place cursor after the indent + "- he" → offset 8
        editor.setSelectedRange(NSRange(location: 8, length: 0))
        editor.insertBacktab(nil)

        #expect(editor.rawSource == "- hello")
        let sel = editor.selectedRange()
        // Cursor shifted back by 4
        #expect(sel.location == 4)
        #expect(sel.length == 0)
    }

    @Test("Full session: type list, indent, type more, undo everything")
    @MainActor func fullIndentSession() {
        let editor = makeEditor()

        // Build a list
        type("- a", into: editor)
        pressEnter(in: editor)
        type("- b", into: editor)
        #expect(editor.rawSource == "- a\n- b")

        // Indent second item
        editor.insertTab(nil)
        #expect(editor.rawSource == "- a\n    - b")

        // Type more on the indented line
        type("ee", into: editor)
        #expect(editor.rawSource == "- a\n    - bee")

        // Undo the typing ("ee")
        editor.undo(nil)
        #expect(editor.rawSource == "- a\n    - b")

        // Undo the indent
        editor.undo(nil)
        #expect(editor.rawSource == "- a\n- b")

        // Undo typing "- b"
        editor.undo(nil)
        #expect(editor.rawSource == "- a\n")

        // Undo Enter
        editor.undo(nil)
        #expect(editor.rawSource == "- a")
    }

    @Test("Tab on non-active block after navigating")
    @MainActor func indentNonActiveBlock() {
        let editor = makeEditor()
        editor.loadContent("- first\n- second\n- third")

        // After loadContent, cursor is at 0, active block is 0.
        // Move cursor to the second block.
        // Block 0 is "- first" (inactive rendered). Block 1 should become active.
        // In the display, block 0 is rendered (shorter due to bullet), block 1 raw.
        // Let's set cursor into block 1's display region.
        let block1DisplayStart = editor.displayRanges[1].location
        editor.setSelectedRange(NSRange(location: block1DisplayStart, length: 0))

        // Trigger recompose so block 1 becomes active
        // (Selection change notification fires async, so drive it manually)
        let rawOffset = editor.displayOffsetToRawOffset(block1DisplayStart)
        editor.recompose(cursorInRaw: rawOffset)

        #expect(editor.activeBlockIndex == 1)

        // Now indent — should indent block 1 only
        editor.insertTab(nil)
        #expect(editor.blocks[0].content == "- first")
        #expect(editor.blocks[1].content == "    - second")
        #expect(editor.blocks[2].content == "- third")
    }

    @Test("Double indent creates 8-space prefix")
    @MainActor func doubleIndent() {
        let editor = makeEditor()
        editor.loadContent("- item")
        editor.setSelectedRange(NSRange(location: 0, length: 0))

        editor.insertTab(nil)
        editor.insertTab(nil)
        #expect(editor.rawSource == "        - item")
        #expect(editor.blocks[0].content.hasPrefix("        - "))

        // Double dedent brings it back
        editor.insertBacktab(nil)
        #expect(editor.rawSource == "    - item")
        editor.insertBacktab(nil)
        #expect(editor.rawSource == "- item")
    }

    @Test("Mixed ordered and unordered list indent together")
    @MainActor func mixedListTypes() {
        let editor = makeEditor()
        editor.loadContent("- bullet\n1. numbered\n+ plus")

        let len = editor.textStorage!.length
        editor.setSelectedRange(NSRange(location: 0, length: len))
        editor.insertTab(nil)

        #expect(editor.rawSource == "    - bullet\n    1. numbered\n    + plus")
    }

    @Test("Checkbox list items indent correctly")
    @MainActor func checkboxIndent() {
        let editor = makeEditor()
        editor.loadContent("- [ ] todo\n- [x] done")

        let len = editor.textStorage!.length
        editor.setSelectedRange(NSRange(location: 0, length: len))
        editor.insertTab(nil)

        #expect(editor.rawSource == "    - [ ] todo\n    - [x] done")
    }
}
