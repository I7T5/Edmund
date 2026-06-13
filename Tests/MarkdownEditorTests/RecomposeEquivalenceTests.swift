import Testing
import AppKit
@testable import MarkdownEditorCore

/// After ANY edit or cursor move, the text storage must be attribute-equivalent
/// to a from-scratch full recompose (the oracle in TestHelpers). These tests
/// pin that equivalence for the current pipeline so the dirty-set / lazy
/// rewrites can be verified against the same bar.
@Suite("Recompose equivalence (oracle)")
struct RecomposeEquivalenceTests {

    /// A document touching every block kind the renderer styles differently.
    static let mixedDocument = """
    # Heading One

    A paragraph with **bold**, *italic*, `code`, and a [link](https://example.com).

    ## Heading Two

    - first item
    - [ ] open task
      - nested item
    1. ordered item

    > [!note]
    > Callout body with **bold** text.

    > A plain quote
    > spanning two lines.

    | Col A | Col B |
    | --- | --- |
    | a | b |

    ```swift
    let x = 1
    ```

    $$
    e = mc^2
    $$

    ---

    Closing paragraph with $inline$ math.
    """

    @MainActor private func loadedEditor() -> EditorTextView {
        let editor = makeEditor()
        editor.loadContent(Self.mixedDocument)
        return editor
    }

    @Test("Freshly loaded document matches the oracle")
    @MainActor func afterLoad() {
        assertMatchesFullRecomposeOracle(loadedEditor())
    }

    @Test("Incremental activation of every block matches the oracle")
    @MainActor func activationSweep() {
        let editor = loadedEditor()
        for i in editor.blocks.indices {
            let target = editor.blocks[i].range.location
            editor.setSelectedRange(NSRange(location: target, length: 0))
            editor.recomposeIncremental(cursorInRaw: target)
            assertMatchesFullRecomposeOracle(editor, "after activating block \(i)")
        }
    }

    @Test("Typing inside a paragraph matches the oracle after every keystroke")
    @MainActor func typingInParagraph() {
        let editor = loadedEditor()
        let para = (editor.rawSource as NSString).range(of: "A paragraph")
        editor.setSelectedRange(NSRange(location: para.location, length: 0))
        editor.recompose(cursorInRaw: para.location)
        for ch in "Hello **w** " {
            type(String(ch), into: editor)
            assertMatchesFullRecomposeOracle(editor, "after typing \(String(reflecting: String(ch)))")
        }
    }

    @Test("Enter-splitting a paragraph matches the oracle")
    @MainActor func enterSplit() {
        let editor = loadedEditor()
        let para = (editor.rawSource as NSString).range(of: "with **bold**")
        editor.setSelectedRange(NSRange(location: para.location, length: 0))
        editor.recompose(cursorInRaw: para.location)
        pressEnter(in: editor)
        assertMatchesFullRecomposeOracle(editor, "after Enter split")
        pressEnter(in: editor)
        assertMatchesFullRecomposeOracle(editor, "after second Enter")
    }

    @Test("Backspace-merging two blocks matches the oracle")
    @MainActor func backspaceMerge() {
        let editor = loadedEditor()
        // Put the cursor at the start of "## Heading Two" and delete the
        // separating newline, merging it into the preceding (blank) block.
        let h2 = (editor.rawSource as NSString).range(of: "## Heading Two")
        editor.setSelectedRange(NSRange(location: h2.location, length: 0))
        editor.recompose(cursorInRaw: h2.location)
        pressBackspace(in: editor)
        assertMatchesFullRecomposeOracle(editor, "after backspace merge")
        pressBackspace(in: editor)
        assertMatchesFullRecomposeOracle(editor, "after second backspace")
    }

    @Test("Multi-block paste matches the oracle")
    @MainActor func multiBlockPaste() {
        let editor = loadedEditor()
        let anchor = (editor.rawSource as NSString).range(of: "Closing paragraph")
        editor.setSelectedRange(NSRange(location: anchor.location, length: 0))
        editor.recompose(cursorInRaw: anchor.location)
        paste("pasted one\n\n## Pasted Heading\n\n> [!tip]\n> pasted callout\n\n", into: editor)
        assertMatchesFullRecomposeOracle(editor, "after multi-block paste")
    }

    @Test("Opening and closing a code fence matches the oracle")
    @MainActor func fenceOpenClose() {
        let editor = loadedEditor()
        let anchor = (editor.rawSource as NSString).range(of: "Closing paragraph")
        editor.setSelectedRange(NSRange(location: anchor.location, length: 0))
        editor.recompose(cursorInRaw: anchor.location)
        // Typing ``` opens an unclosed fence that absorbs the rest of the doc.
        for ch in "```\n" {
            type(String(ch), into: editor)
            assertMatchesFullRecomposeOracle(editor, "after typing \(String(reflecting: String(ch))) (open)")
        }
        paste("```\n", into: editor)
        assertMatchesFullRecomposeOracle(editor, "after closing the fence")
    }

    @Test("Undo and redo match the oracle")
    @MainActor func undoRedo() {
        let editor = loadedEditor()
        let para = (editor.rawSource as NSString).range(of: "A paragraph")
        editor.setSelectedRange(NSRange(location: para.location, length: 0))
        editor.recompose(cursorInRaw: para.location)
        type("edit ", into: editor)
        editor.performUndo()
        assertMatchesFullRecomposeOracle(editor, "after undo")
        editor.performRedo()
        assertMatchesFullRecomposeOracle(editor, "after redo")
    }

    @Test("Tab / Shift-Tab indent matches the oracle")
    @MainActor func indentMatchesOracle() {
        let editor = loadedEditor()
        // Cursor inside a list item, then indent and dedent it.
        let item = (editor.rawSource as NSString).range(of: "first item")
        editor.setSelectedRange(NSRange(location: item.location, length: 0))
        editor.recompose(cursorInRaw: item.location)
        editor.insertTab(nil)
        assertMatchesFullRecomposeOracle(editor, "after Tab indent")
        editor.insertBacktab(nil)
        assertMatchesFullRecomposeOracle(editor, "after Shift-Tab dedent")
    }

    @Test("Multi-line indent across a selection matches the oracle")
    @MainActor func multiLineIndentMatchesOracle() {
        let editor = makeEditor()
        editor.loadContent("- a\n- b\n- c\n")
        // Select all three list lines and indent them together.
        editor.setSelectedRange(NSRange(location: 0, length: (editor.rawSource as NSString).length))
        editor.insertTab(nil)
        assertMatchesFullRecomposeOracle(editor, "after multi-line indent")
        #expect(editor.rawSource == "  - a\n  - b\n  - c\n")
    }

    @Test("Indent that shifts the global list-indent unit restyles every list item")
    @MainActor func indentUnitChangeMatchesOracle() {
        let editor = makeEditor()
        // Only indented list line is at 4 spaces, so the unit is 4.
        editor.loadContent("- a\n    - deep\n")
        #expect(editor.listIndentUnit == 4)
        // Indent the top-level item by 2: the new minimum indent is 2, so the
        // unit drops to 2 and every list block's rendered indent changes.
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.recompose(cursorInRaw: 0)
        editor.insertTab(nil)
        #expect(editor.listIndentUnit == 2)
        assertMatchesFullRecomposeOracle(editor, "after unit-shifting indent")
    }

    @Test("Edit sequence on a generated document matches the oracle")
    @MainActor func generatedDocumentEdits() {
        let editor = makeEditor()
        editor.loadContent(makeLargeMarkdown(approximateBytes: 20_000, seed: 7))
        assertMatchesFullRecomposeOracle(editor, "after load")

        let ns = editor.rawSource as NSString
        let mid = editor.blockIndexForRawOffset(ns.length / 2) ?? 0
        let target = editor.blocks[mid].range.location
        editor.setSelectedRange(NSRange(location: target, length: 0))
        editor.recomposeIncremental(cursorInRaw: target)
        assertMatchesFullRecomposeOracle(editor, "after mid-doc activation")

        type("xyz", into: editor)
        assertMatchesFullRecomposeOracle(editor, "after mid-doc typing")
        pressEnter(in: editor)
        assertMatchesFullRecomposeOracle(editor, "after mid-doc Enter")
    }
}
