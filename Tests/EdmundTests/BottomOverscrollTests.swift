import Testing
import AppKit
@testable import EdmundCore

/// With typewriter scroll off, the document can be scrolled half a viewport
/// past its last line, so the line being written is never pinned to the bottom
/// edge of the window. (Typewriter scroll reserves that space in its own
/// container inset instead — see TypewriterCenteringTests.)
@Suite("Bottom overscroll")
struct BottomOverscrollTests {

    @MainActor
    private func makeWindowed(typewriter: Bool) -> (EditorTextView, NSScrollView) {
        let editor = makeEditor()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
                           styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: win.contentLayoutRect)
        scroll.documentView = editor
        win.contentView = scroll
        win.makeFirstResponder(editor)
        editor.isVerticallyResizable = true
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]
        editor.textContainerInset = NSSize(width: 24,
                                           height: EditorTextView.contentBaseVerticalInset)
        editor.typewriterModeEnabled = typewriter
        editor.updateContentInset()
        editor.updateScrollOverscroll()
        var doc = ""
        for i in 1...100 { doc += "Line \(i) content here for the document body.\n" }
        editor.loadContent(doc)
        ensureFullLayout(editor); editor.sizeToFit(); editor.layoutSubtreeIfNeeded()
        return (editor, scroll)
    }

    /// Scrolled all the way down, half a viewport of blank space must sit below
    /// the last line — that's the room the line being written needs.
    @Test("Scrolls half a viewport past the last line")
    @MainActor func overscrollsPastEnd() {
        let (editor, scroll) = makeWindowed(typewriter: false)
        let clipHeight = scroll.contentView.bounds.height
        let lastLine = editor.lineRect(forCharacterAt: (editor.rawSource as NSString).length - 1)
        guard let lastLine else { Issue.record("no last line rect"); return }
        let documentBottom = lastLine.maxY + editor.textContainerOrigin.y
        let blankBelow = editor.clampedScrollY(99_999) + clipHeight - documentBottom
        #expect(blankBelow >= clipHeight / 2 - 1,
                "only \(blankBelow)pt below the last line, wanted \(clipHeight / 2)")
    }

    /// Re-running the pass must not accumulate — it sets an absolute padding
    /// rather than adding to the current one.
    @Test("Re-running the overscroll pass doesn't compound it")
    @MainActor func idempotent() {
        let (editor, _) = makeWindowed(typewriter: false)
        let first = editor.textContainerInset.height
        editor.updateScrollOverscroll()
        editor.updateScrollOverscroll()
        #expect(abs(editor.textContainerInset.height - first) < 1,
                "vertical inset grew from \(first) to \(editor.textContainerInset.height)")
    }

    /// The bottom room is wanted in both modes — typewriter scroll needs it to
    /// center the last line, plain scrolling to write past the end.
    @Test("Bottom room is reserved in typewriter mode too")
    @MainActor func alsoInTypewriterMode() {
        let (editor, scroll) = makeWindowed(typewriter: true)
        let clipHeight = scroll.contentView.bounds.height
        #expect(editor.overscrollBottomPad >= clipHeight / 2 - 1,
                "bottom overscroll missing in typewriter mode: \(editor.overscrollBottomPad)")
    }

    /// The blank band below the last line is part of the text view, so clicking
    /// it puts the caret on the nearest character instead of doing nothing.
    @Test("Clicks in the blank band below the text reach the editor")
    @MainActor func bandBelowTextIsClickable() {
        let (editor, scroll) = makeWindowed(typewriter: false)
        editor.loadContent("Only line.\n")
        ensureFullLayout(editor); editor.sizeToFit(); editor.layoutSubtreeIfNeeded()
        let hit = scroll.hitTest(NSPoint(x: scroll.bounds.midX, y: 5))
        #expect(hit === editor,
                "click below the text landed on \(hit.map { "\(type(of: $0))" } ?? "nothing")")
    }
}
