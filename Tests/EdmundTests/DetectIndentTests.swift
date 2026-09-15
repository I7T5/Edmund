import Testing
@testable import EdmundCore

// Detect-indent heuristic (Edit ▸ Indentation ▸ "Detect and learn indent style
// on document opening"). Pure String scan — no editor/window needed.

@Suite("EditorTextView — detect indent")
struct DetectIndentTests {

    @Test("Tab-indented file detects tabs")
    @MainActor func tabs() {
        let d = EditorTextView.detectIndent(in: "- a\n\t- b\n\t- c")
        #expect(d?.usesTabs == true)
    }

    @Test("Four-space file detects spaces, width 4")
    @MainActor func fourSpaces() {
        let d = EditorTextView.detectIndent(in: "- a\n    - b\n    - c")
        #expect(d?.usesTabs == false)
        #expect(d?.width == 4)
    }

    @Test("Two-space file detects spaces, width 2")
    @MainActor func twoSpaces() {
        let d = EditorTextView.detectIndent(in: "- a\n  - b\n  - c")
        #expect(d?.usesTabs == false)
        #expect(d?.width == 2)
    }

    @Test("Unindented file detects nothing")
    @MainActor func none() {
        #expect(EditorTextView.detectIndent(in: "a\nb\nc") == nil)
    }
}
