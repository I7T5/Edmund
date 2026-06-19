import Testing
import AppKit
@testable import EdmundCore

/// Typewriter mode keeps the caret at the vertical center of the viewport.
/// The failure mode this guards against: centering measured the caret from a
/// TextKit 2 height estimate (fragments above the caret not laid out), so the
/// caret landed off-center — consistently low in the bug report. Centering now
/// lays out the bounded viewport↔caret span first; these tests pin that the
/// caret ends within a couple points of center, including after scrolling away.
@Suite("Typewriter centering")
struct TypewriterCenteringTests {

    @MainActor
    private func makeWindowed() -> (EditorTextView, NSScrollView) {
        let editor = makeEditor()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
                           styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: win.contentLayoutRect)
        scroll.documentView = editor
        win.contentView = scroll
        win.makeFirstResponder(editor)
        editor.typewriterModeEnabled = true
        editor.isVerticallyResizable = true
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]
        return (editor, scroll)
    }

    /// Caret's distance (pts) from the viewport's vertical center after centering.
    @MainActor
    private func offFromCenter(_ editor: EditorTextView, _ scroll: NSScrollView,
                               caretOffset off: Int) -> CGFloat {
        editor.setSelectedRange(NSRange(location: off, length: 0))
        editor.scrollCursorToCenter()
        editor.layoutSubtreeIfNeeded()
        guard let lr = editor.lineRect(forCharacterAt: off) else { return .greatestFiniteMagnitude }
        let docY = lr.midY + editor.textContainerOrigin.y
        let screenMid = docY - scroll.contentView.bounds.origin.y
        return abs(screenMid - scroll.contentView.bounds.height / 2)
    }

    @Test("Caret centers on mid-document lines")
    @MainActor func centersMidDocument() {
        let (editor, scroll) = makeWindowed()
        var doc = ""
        for i in 1...100 { doc += "Line \(i) content here for the document body.\n" }
        editor.loadContent(doc)
        ensureFullLayout(editor); editor.sizeToFit(); editor.layoutSubtreeIfNeeded()

        let ns = editor.rawSource as NSString
        for marker in ["Line 30 ", "Line 50 ", "Line 70 "] {
            let off = ns.range(of: marker).location
            let delta = offFromCenter(editor, scroll, caretOffset: off)
            #expect(delta < 4, "\(marker) off-center by \(delta)pt")
        }
    }

    @Test("Caret centers on a line scrolled out of view")
    @MainActor func centersAfterScrollingAway() {
        let (editor, scroll) = makeWindowed()
        var doc = ""
        for i in 1...100 { doc += "Line \(i) content here for the document body.\n" }
        editor.loadContent(doc)
        ensureFullLayout(editor); editor.sizeToFit(); editor.layoutSubtreeIfNeeded()

        // Scroll to the bottom so an early line is well off-screen, then center
        // on it — this is the path that read a stale estimate before the fix.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, editor.frame.height - scroll.contentView.bounds.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
        editor.layoutSubtreeIfNeeded()

        let off = (editor.rawSource as NSString).range(of: "Line 20 ").location
        let delta = offFromCenter(editor, scroll, caretOffset: off)
        #expect(delta < 4, "off-screen line off-center by \(delta)pt")
    }
}
