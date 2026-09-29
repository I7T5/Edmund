import Testing
import AppKit
@testable import EdmundCore

@Suite("Active-block span cache")
@MainActor
struct ActiveSpanCacheTests {
    @Test("Moving to another line changes the cursor styling signature")
    func lineRevealedMarkers() {
        let editor = makeEditor()
        editor.loadContent("> first\n> second")
        editor.recompose(cursorInRaw: 3)
        editor.applyBlockStyle()
        let firstLineSignature = editor.appliedCursorSpans
        #expect(firstLineSignature != nil)

        editor.setSelectedRange(NSRange(location: 11, length: 0))
        editor.applyBlockStyle()
        #expect(editor.appliedCursorSpans != firstLineSignature)
        assertMatchesFullRecomposeOracle(editor)
    }

    @Test("Caret moves in a deep list continuation preserve inline styling and indentation")
    func continuationCaretMoves() throws {
        let editor = makeEditor()
        editor.loadContent("- outer\n    - inner\n      **bold** tail\nafter")
        let continuation = 2
        let start = editor.blocks[continuation].range.location
        #expect(editor.listContinuationDepth(ofBlock: continuation) == 1)
        editor.recompose(cursorInRaw: start + 8)

        // Exercise both the first parse and cache hits, crossing the bold
        // delimiter boundary and moving within the plain tail.
        for offset in [8, 15, 16, 9] {
            editor.setSelectedRange(NSRange(location: start + offset, length: 0))
            editor.applyBlockStyle()
            let bold = try #require(font(at: start + 8, in: editor))
            #expect(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
            #expect(isHidden(at: start, in: try #require(editor.textStorage)))
            assertMatchesFullRecomposeOracle(editor, "caret within a list continuation")
        }
    }

    @Test("Identical content in code and list continuations cannot share parsed spans")
    func continuationContextChanges() throws {
        let editor = makeEditor()
        let content = "      **bold** tail"
        editor.loadContent(content + "\n\n- outer\n    - inner\n" + content + "\nafter")
        let matches = editor.blocks.indices.filter { editor.blocks[$0].content == content }
        #expect(matches.count == 2)
        let code = try #require(matches.first)
        let continuation = try #require(matches.last)
        #expect(editor.listContinuationDepth(ofBlock: code) == nil)
        #expect(editor.listContinuationDepth(ofBlock: continuation) == 1)

        // Revisit each context with byte-identical content, definitions and
        // features; only continuationDepth distinguishes their parse inputs.
        for index in [code, continuation, code, continuation] {
            let start = editor.blocks[index].range.location
            editor.recompose(cursorInRaw: start + 8)
            editor.applyBlockStyle()
            assertMatchesFullRecomposeOracle(editor, "same content in a different parse context")
        }
    }

    @Test("Full recompose invalidates the last applied cursor signature")
    func fullRecomposeInvalidatesSignature() {
        let editor = makeEditor()
        editor.loadContent("# Heading **bold**")
        editor.recompose(cursorInRaw: 12)
        editor.applyBlockStyle()
        #expect(editor.appliedCursorSpans != nil)

        editor.recomposeAllDirty()
        #expect(editor.appliedCursorSpans == nil)
        editor.applyBlockStyle()
        #expect(editor.appliedCursorSpans != nil)
        assertMatchesFullRecomposeOracle(editor)
    }
}
