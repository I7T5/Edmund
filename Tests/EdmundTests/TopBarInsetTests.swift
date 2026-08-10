import Testing
import AppKit
@testable import EdmundCore

/// The top chrome bars (format bar, find bar) push the document down through the
/// scroll view's `contentInsets.top` rather than by padding the text container.
/// The distinction the tests below pin: a content inset moves the document and
/// the scroll range together, while container padding would buy the same room as
/// document height — scrollable emptiness above the first line that the reader
/// can wander into and that stays behind once the bar closes.
@Suite("Top bar inset")
struct TopBarInsetTests {

    @MainActor
    private func makeWindowed(typewriter: Bool = false) -> (EditorTextView, NSScrollView) {
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

    @Test("Bar height lands on contentInsets, not on document height")
    @MainActor func insetNotOverscroll() {
        let (editor, scroll) = makeWindowed()
        let heightBefore = editor.frame.height
        editor.additionalTopInset = 64
        #expect(abs(scroll.contentInsets.top - 64) < 0.5,
                "contentInsets.top = \(scroll.contentInsets.top), wanted 64")
        #expect(abs(editor.frame.height - heightBefore) < 0.5,
                "document grew \(editor.frame.height - heightBefore)pt — that is overscroll")
    }

    /// The point of the change: opening a bar pushes the text down out from
    /// under it. Sitting at the top of the document, the resting scroll position
    /// moves from 0 to -inset, which is the document sliding down by `inset`.
    @Test("Opening a bar bumps the document down by its height")
    @MainActor func barBumpsContentDown() {
        let (editor, scroll) = makeWindowed()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        editor.additionalTopInset = 64
        #expect(abs(scroll.contentView.bounds.origin.y + 64) < 0.5,
                "origin.y = \(scroll.contentView.bounds.origin.y), wanted -64")
    }

    /// And closing it pulls the text back up — no residual gap.
    @Test("Closing the bar restores the original position")
    @MainActor func closingRestores() {
        let (editor, scroll) = makeWindowed()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        editor.additionalTopInset = 64
        editor.additionalTopInset = 0
        #expect(abs(scroll.contentInsets.top) < 0.5)
        #expect(abs(scroll.contentView.bounds.origin.y) < 0.5,
                "origin.y = \(scroll.contentView.bounds.origin.y), wanted 0")
    }

    /// Nothing above the first line to scroll into: with the bars up, the top of
    /// the scroll range is exactly the inset and no further.
    @Test("No scrollable emptiness above the first line")
    @MainActor func noRoomAboveTheTop() {
        let (editor, _) = makeWindowed()
        editor.additionalTopInset = 64
        #expect(abs(editor.clampedScrollY(-9_999) + 64) < 0.5,
                "top of range = \(editor.clampedScrollY(-9_999)), wanted -64")
    }

    /// Typewriter mode centres on what the reader can see. With a 64pt bar over
    /// a 320pt clip the caret belongs at 64 + 128 = 192 from the clip top, not
    /// at 160 — the old maths put it behind the bar.
    @Test("Typewriter centres below the bars, not behind them")
    @MainActor func typewriterCentresInVisibleBand() {
        let (editor, scroll) = makeWindowed(typewriter: true)
        editor.additionalTopInset = 64
        editor.setSelectedRange(NSRange(location: 2_000, length: 0))
        editor.centerViewportOnCaret()
        guard let caret = editor.lineRect(forCharacterAt: 2_000) else {
            Issue.record("no caret rect"); return
        }
        let caretOnScreen = caret.midY + editor.textContainerOrigin.y
            - scroll.contentView.bounds.origin.y
        let wanted = 64 + (scroll.contentView.bounds.height - 64) / 2
        #expect(abs(caretOnScreen - wanted) < 4,
                "caret sits \(caretOnScreen)pt from the clip top, wanted \(wanted)")
    }
}
