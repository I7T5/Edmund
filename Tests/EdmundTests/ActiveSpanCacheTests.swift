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
