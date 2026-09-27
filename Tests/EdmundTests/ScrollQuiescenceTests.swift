import Testing
import AppKit
@testable import EdmundCore

@Suite("User-scroll quiescence")
@MainActor
struct ScrollQuiescenceTests {
    private func windowedEditor() -> (EditorTextView, NSScrollView, NSWindow) {
        let editor = makeEditor()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: window.contentLayoutRect)
        scroll.documentView = editor
        window.contentView = scroll
        window.makeFirstResponder(editor)
        editor.typewriterModeEnabled = false
        editor.isVerticallyResizable = true
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]
        editor.installScrollPromotionObserver()
        return (editor, scroll, window)
    }

    private func loadDocument(_ editor: EditorTextView) {
        editor.loadContent((0..<800).map { "paragraph **number** \($0)" }
            .joined(separator: "\n\n"))
        ensureFullLayout(editor)
        editor.sizeToFit()
        editor.layoutSubtreeIfNeeded()
        #expect(editor.blocks.last?.isStyled == false)
    }

    private func scrollToBottom(_ editor: EditorTextView, _ scroll: NSScrollView) {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, editor.frame.height - 300)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func expectVisibleStyling(_ editor: EditorTextView) throws {
        let visible = try #require(editor.syncStylingBlockRange())
        #expect(!visible.isEmpty)
        #expect(visible.allSatisfy { editor.blocks[$0].isStyled })
        #expect(editor.blocks.last?.isStyled == true)
        // Check actual output as well as bookkeeping: inactive bold syntax
        // entering the viewport must be hidden, not left in base attributes.
        let last = try #require(editor.blocks.last)
        let marker = last.range.location + (last.content as NSString).range(of: "**").location
        #expect(isHidden(at: marker, in: try #require(editor.textStorage)))
        assertMatchesFullRecomposeOracle(editor)
    }

    @Test("Live scrolling promotes visible blocks while the queued idle drain stays paused")
    func liveScrollPromotes() throws {
        let (editor, scroll, window) = windowedEditor()
        defer { withExtendedLifetime(window) {} }
        loadDocument(editor) // Queues a drain before the gesture starts.
        #expect(editor.progressiveStylingScheduled)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification,
                                        object: scroll)
        scrollToBottom(editor, scroll)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))

        #expect(editor.isScrollingActive)
        try expectVisibleStyling(editor)
        #expect(!editor.blocks[editor.blocks.count / 2].isStyled,
                "the queued idle drain must not run during live scrolling")
        #expect(!editor.progressiveStylingScheduled)
        #expect(!editor.fullLayoutSettleScheduled)
    }

    @Test("Promotion continues during settling and the idle drain resumes afterward")
    func scrollEndResumesStyling() throws {
        let (editor, scroll, window) = windowedEditor()
        defer { withExtendedLifetime(window) {} }
        loadDocument(editor)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification,
                                        object: scroll)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification,
                                        object: scroll)
        scrollToBottom(editor, scroll)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        #expect(editor.isScrollingActive)
        try expectVisibleStyling(editor)
        #expect(!editor.blocks[editor.blocks.count / 2].isStyled)

        let unstyledBeforeSettle = editor.blocks.filter { !$0.isStyled }.count
        let deadline = Date().addingTimeInterval(2)
        while (editor.isScrollingActive
               || editor.blocks.filter { !$0.isStyled }.count == unstyledBeforeSettle),
              Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        #expect(!editor.isScrollingActive)
        #expect(editor.blocks.filter { !$0.isStyled }.count < unstyledBeforeSettle,
                "the run loop must resume background styling after quiescence")
        try expectVisibleStyling(editor)
    }

    @Test("Programmatic scrolling promotes on the next run-loop turn without the idle drain")
    func programmaticScrollPromotes() throws {
        let (editor, scroll, window) = windowedEditor()
        defer { withExtendedLifetime(window) {} }
        // Suppress idle scheduling so the drain cannot mask broken promotion.
        editor.progressiveStylingScheduled = true
        loadDocument(editor)
        scrollToBottom(editor, scroll)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        #expect(!editor.isScrollingActive)
        #expect(editor.scrollQuiescenceTimer == nil)
        try expectVisibleStyling(editor)
        #expect(!editor.blocks[editor.blocks.count / 2].isStyled)
    }

    @Test("Programmatic bounds changes do not extend the user-scroll gate")
    func programmaticBoundsChanges() {
        let (editor, scroll, window) = windowedEditor()
        defer { withExtendedLifetime(window) {} }
        loadDocument(editor)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification,
                                        object: scroll)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification,
                                        object: scroll)
        let timer = editor.scrollQuiescenceTimer
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
        #expect(editor.scrollQuiescenceTimer === timer)
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        #expect(!editor.isScrollingActive)
    }
}
