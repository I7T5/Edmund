import Testing
import AppKit
@testable import MarkdownEditorCore

@Suite("View modes")
@MainActor
struct ViewModeTests {

    private func font(_ editor: EditorTextView, at loc: Int) -> NSFont? {
        editor.textStorage?.attribute(.font, at: loc, effectiveRange: nil) as? NSFont
    }

    @Test("Source mode shows plain monospace raw markdown")
    func sourceMode() {
        let editor = makeEditor()
        editor.loadContent("# Heading\n\nThis is **bold**.")
        editor.viewMode = .source

        // The `#` heading marker keeps body size + monospace (not a big heading).
        let f0 = font(editor, at: 0)
        #expect(f0?.isFixedPitch == true)
        #expect((f0?.pointSize ?? 99) <= editor.bodyFont.pointSize)
        // The `**` bold markers aren't hidden — everything is shown raw.
        let boldLoc = (editor.rawSource as NSString).range(of: "**bold**").location
        #expect(!isHidden(at: boldLoc, in: editor.textStorage!))
        #expect(font(editor, at: boldLoc)?.isFixedPitch == true)
    }

    @Test("Reading mode never reveals raw markers, even with a caret in the block")
    func readingMode() {
        let editor = makeEditor()
        editor.loadContent("**bold**")
        editor.viewMode = .reading
        // Put the caret inside the token; reading mode must keep `**` hidden.
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        editor.recomposeDirty(IndexSet(integersIn: 0..<editor.blocks.count), cursorInRaw: 3)
        #expect(isHidden(at: 0, in: editor.textStorage!))
        #expect(editor.isEditable == false)
    }

    @Test("Edit mode reveals the active block's raw markers")
    func editModeReveals() {
        let editor = makeEditor()
        editor.loadContent("**bold**")
        editor.viewMode = .edit
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        editor.recomposeDirty(IndexSet(integersIn: 0..<editor.blocks.count), cursorInRaw: 3)
        // Active token shows dimmed (visible) `**`, not hidden.
        #expect(!isHidden(at: 0, in: editor.textStorage!))
        #expect(editor.isEditable == true)
    }
}
