import Testing
import AppKit
@testable import EdmundCore

@Suite("View modes")
@MainActor
struct ViewModeTests {

    private func font(_ editor: EditorTextView, at loc: Int) -> NSFont? {
        editor.textStorage?.attribute(.font, at: loc, effectiveRange: nil) as? NSFont
    }

    /// Edit ↔ Read restyles only the blocks that differ between the two (the
    /// active block, comments, block refs). The result must equal a full
    /// restyle, which going through Source still does.
    @Test("Edit ↔ Read ends where a full restyle would")
    func editReadSwitchMatchesFullRestyle() {
        let doc = """
        # Title ^h1

        Para with %%hidden%% and **bold** <!-- note -->.

        - item ^ref
        - other *item*

        > quote with `code`

        foot[^1] and [[Wiki]]

        [^1]: the note

        last **para**
        """
        let caret = (doc as NSString).range(of: "bold").location
        func editor(through modes: [EditorTextView.ViewMode]) -> EditorTextView {
            let e = makeEditor()
            e.loadContent(doc)
            e.setSelectedRange(NSRange(location: caret, length: 0))
            e.recomposeIncremental(cursorInRaw: caret)
            for m in modes { e.viewMode = m }
            return e
        }
        var path: [EditorTextView.ViewMode] = []
        for mode in [EditorTextView.ViewMode.reading, .edit, .reading, .edit] {
            path.append(mode)
            let live = editor(through: path)
            let full = editor(through: [.source, mode])
            guard let a = live.textStorage, let b = full.textStorage else { continue }
            var i = 0
            while i < a.length {
                var ra = NSRange(), rb = NSRange()
                let whole = NSRange(location: i, length: a.length - i)
                let diff = attributeDifference(expected: b.attributes(at: i, longestEffectiveRange: &rb, in: whole),
                                               actual: a.attributes(at: i, longestEffectiveRange: &ra, in: whole))
                if let diff { Issue.record("after \(path): offset \(i): \(diff)"); break }
                i = max(min(ra.upperBound, rb.upperBound), i + 1)
            }
        }
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
