import Testing
import AppKit
@testable import MarkdownEditorCore

// When you click into a bullet item, the raw "-" should stay on the dot's
// column (where the rendered • sits) rather than jumping a slot to the right.
// Content must still hang at the same indent so the text doesn't move.
@Suite("Active bullet marker column")
@MainActor
struct ActiveBulletMarkerTests {

    private func ps(_ editor: EditorTextView, _ s: String, cursor: Int?) -> NSParagraphStyle? {
        let st = editor.styleBlock(s, cursorPosition: cursor)
        return st.attribute(.paragraphStyle, at: st.length - 1, effectiveRange: nil) as? NSParagraphStyle
    }

    @Test("Active bullet marker stays on the dot column (not right-aligned into the slot)")
    func bulletStaysOnDotColumn() {
        let editor = makeEditor()
        let active = ps(editor, "- item", cursor: 3)!
        let inactive = ps(editor, "- item", cursor: nil)!
        let slot = editor.bodyFont.pointSize +
            (" " as NSString).size(withAttributes: [.font: editor.bodyFont]).width
        // The active dash sits on the inactive dot's column (within a fraction of
        // a slot), not a full slot to the right of it.
        #expect(abs(active.firstLineHeadIndent - inactive.firstLineHeadIndent) < slot * 0.5)
        // Content is unchanged so the text doesn't shift when clicking in.
        #expect(abs(active.headIndent - inactive.headIndent) < 0.5)
    }

    @Test("Active bullet kerns its trailing space so content keeps the hanging indent")
    func bulletKernsTrailingSpace() {
        let editor = makeEditor()
        let st = editor.styleBlock("- item", cursorPosition: 3)
        // "- item": the space is index 1; it carries positive kern to push the
        // content out to the content indent even though the dash sits left.
        let kern = st.attribute(.kern, at: 1, effectiveRange: nil) as? CGFloat
        #expect((kern ?? 0) > 0)
    }

    @Test("Active ordered marker still right-aligns into its slot")
    func orderedStillRightAligns() {
        let editor = makeEditor()
        let active = ps(editor, "1. item", cursor: 4)!
        // Ordered numbers keep right-alignment (periods line up), so the first
        // line indent is well right of the bullet column.
        #expect(active.firstLineHeadIndent < active.headIndent)
        #expect(active.firstLineHeadIndent > editor.listPadding + 1)
    }
}
