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
        // Mirror Document's setup: the app's own inset, then the overscroll
        // pass. The overscroll is half the clip height, so it can't be computed
        // before the editor has an enclosing scroll view.
        editor.textContainerInset = NSSize(width: 24,
                                           height: EditorTextView.contentBaseVerticalInset)
        editor.updateContentInset()
        editor.updateScrollOverscroll()
        return (editor, scroll)
    }

    /// Caret's distance (pts) from the viewport's vertical center after centering.
    @MainActor
    private func offFromCenter(_ editor: EditorTextView, _ scroll: NSScrollView,
                               caretOffset off: Int) -> CGFloat {
        editor.setSelectedRange(NSRange(location: off, length: 0))
        // Center, settle the real (non-estimated) heights, then center again on
        // that settled layout — so the measurement isn't comparing two different
        // height estimates. (In the app the layout is already stable; the test
        // forces convergence because ensureFullLayout / inset changes here churn it.)
        editor.scrollCursorToCenter()
        ensureFullLayout(editor)
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

    /// The document's ends. Centering clamps the scroll to
    /// [0, frame.height - viewportHeight], so without typewriter mode's
    /// half-viewport padding the first and last screenful can't reach center —
    /// the caret just sat wherever it was.
    @Test("Caret centers on the first and last line")
    @MainActor func centersAtDocumentEnds() {
        let (editor, scroll) = makeWindowed()
        var doc = ""
        for i in 1...100 { doc += "Line \(i) content here for the document body.\n" }
        editor.loadContent(doc)
        ensureFullLayout(editor); editor.sizeToFit(); editor.layoutSubtreeIfNeeded()

        let ns = editor.rawSource as NSString
        for marker in ["Line 1 ", "Line 100 "] {
            let off = ns.range(of: marker).location
            let delta = offFromCenter(editor, scroll, caretOffset: off)
            let lr = editor.lineRect(forCharacterAt: off)
            #expect(delta < 4, """
                \(marker)off-center by \(delta)pt — \
                clipH=\(scroll.contentView.bounds.height) \
                inset=\(editor.textContainerInset.height) \
                frameH=\(editor.frame.height) \
                originY=\(editor.textContainerOrigin.y) \
                lineRect=\(lr.map { "\($0)" } ?? "nil") \
                scrollY=\(scroll.contentView.bounds.origin.y)
                """)
        }
    }

    /// A document shorter than the window: with no padding the clamp range is
    /// [0, 0] and centering could not move the viewport at all.
    @Test("Caret centers in a document shorter than the viewport")
    @MainActor func centersInShortDocument() {
        let (editor, scroll) = makeWindowed()
        editor.loadContent("Line 1 alpha\nLine 2 beta\nLine 3 gamma\nLine 4 delta\nLine 5 epsilon\n")
        ensureFullLayout(editor); editor.sizeToFit(); editor.layoutSubtreeIfNeeded()

        let off = (editor.rawSource as NSString).range(of: "Line 3 ").location
        let delta = offFromCenter(editor, scroll, caretOffset: off)
        #expect(delta < 4, "short-document line off-center by \(delta)pt")
    }

    /// Centering can only reach the first line if there is blank space above
    /// the document's start. It is reserved inside the text view's own frame
    /// (`textContainerOrigin`), so the first line begins half a viewport down.
    @Test("Blank space is reserved above the first line")
    @MainActor func spaceReservedAboveStart() {
        let (editor, scroll) = makeWindowed()
        var doc = ""
        for i in 1...100 { doc += "Line \(i) content here for the document body.\n" }
        editor.loadContent(doc)
        ensureFullLayout(editor); editor.sizeToFit(); editor.layoutSubtreeIfNeeded()

        let clipH = scroll.contentView.bounds.height
        #expect(editor.clampedScrollY(-99_999) >= -0.5,
                "the padding belongs inside the frame; the scroll range must still start at 0")
        #expect(editor.textContainerOrigin.y >= clipH / 2 - 1,
                "first line starts \(editor.textContainerOrigin.y)pt down, wanted >= \(clipH / 2)")
    }

    /// The space above the first line is typewriter-only — with the mode off
    /// there is no blank band over the opening line.
    @Test("Space above the first line exists only in typewriter mode")
    @MainActor func topSpaceIsModeScoped() {
        let (editor, scroll) = makeWindowed()
        editor.loadContent("Body text.\n")
        editor.updateScrollOverscroll()
        let clipH = scroll.contentView.bounds.height
        #expect(editor.overscrollTopPad >= clipH / 2 - 1,
                "typewriter top overscroll missing: \(editor.overscrollTopPad)")

        editor.typewriterModeEnabled = false
        #expect(editor.overscrollTopPad < 0.5,
                "top overscroll leaked into normal mode: \(editor.overscrollTopPad)")
        #expect(editor.textContainerOrigin.y <= EditorTextView.contentBaseVerticalInset + 0.5,
                "text still starts \(editor.textContainerOrigin.y)pt down with the mode off")
        #expect(editor.overscrollBottomPad >= clipH / 2 - 1,
                "bottom overscroll should stay in both modes: \(editor.overscrollBottomPad)")
    }

    /// The regression that shipped in #260: the overscroll used to live in
    /// `NSScrollView.contentInsets`, and AppKit restricts hit-testing to the
    /// scroll view's frame *minus* its insets. Half a viewport at each end left
    /// a zero-height live area, so no click anywhere in the window reached the
    /// text — the caret stopped following clicks entirely.
    @Test("Every point of the window still routes clicks to the editor")
    @MainActor func windowStaysClickable() {
        let (editor, scroll) = makeWindowed()
        var doc = ""
        for i in 1...100 { doc += "Line \(i) content here for the document body.\n" }
        editor.loadContent(doc)
        ensureFullLayout(editor); editor.sizeToFit(); editor.layoutSubtreeIfNeeded()

        let h = scroll.bounds.height
        for y in [h - 5, h * 0.75, h / 2, h * 0.25, 5] {
            let hit = scroll.hitTest(NSPoint(x: scroll.bounds.midX, y: y))
            #expect(hit === editor,
                    "click at y=\(y) landed on \(hit.map { "\(type(of: $0))" } ?? "nothing"), not the editor")
        }
    }
}
