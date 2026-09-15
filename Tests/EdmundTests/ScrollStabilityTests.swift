import Testing
import AppKit
@testable import EdmundCore

/// Activating/deactivating a block ABOVE the viewport changes its height
/// (callout header line + padding vs raw text). TextKit 2 lays out
/// viewport-relative, so content under the scroll position must not jump.
@Suite("Scroll stability under height changes")
struct ScrollStabilityTests {

    @Test("Callout activation above the viewport doesn't shift visible content")
    @MainActor func activationAboveViewport() {
        let editor = makeEditor()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                           styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: win.contentLayoutRect)
        scroll.documentView = editor
        win.contentView = scroll
        win.makeFirstResponder(editor)
        editor.typewriterModeEnabled = false
        editor.isVerticallyResizable = true
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]

        var doc = "> [!note]\n> callout body\n\n"
        for i in 0..<60 { doc += "paragraph number \(i)\n\n" }
        editor.loadContent(doc)
        ensureFullLayout(editor)
        editor.sizeToFit()
        editor.layoutSubtreeIfNeeded()

        // Scroll well past the callout.
        let target = (editor.rawSource as NSString).range(of: "paragraph number 40").location
        editor.setSelectedRange(NSRange(location: target, length: 0))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 800))
        scroll.reflectScrolledClipView(scroll.contentView)
        let yBefore = scroll.contentView.bounds.origin.y
        #expect(yBefore > 0)

        // Activate the callout (height change above the viewport), then deactivate.
        editor.recomposeIncremental(cursorInRaw: 2)
        editor.recomposeIncremental(cursorInRaw: target)
        ensureFullLayout(editor)
        editor.layoutSubtreeIfNeeded()

        let yAfter = scroll.contentView.bounds.origin.y
        #expect(abs(yAfter - yBefore) < 2.0,
                "scroll position jumped by \(yAfter - yBefore)")
    }

    @Test("Tab-indenting a list in the viewport doesn't lurch the scroll")
    @MainActor func indentDoesNotLurch() {
        let editor = makeEditor()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                           styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: win.contentLayoutRect)
        scroll.documentView = editor
        win.contentView = scroll
        win.makeFirstResponder(editor)
        editor.typewriterModeEnabled = false   // exercise the viewport-top anchor
        editor.isVerticallyResizable = true
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]

        // Plenty of content above a list, so the list sits deep in the document.
        var doc = ""
        for i in 0..<40 { doc += "paragraph number \(i)\n\n" }
        doc += "- list item alpha\n- list item beta\n- list item gamma\n\n"
        for i in 0..<20 { doc += "tail paragraph \(i)\n\n" }
        editor.loadContent(doc)
        ensureFullLayout(editor)
        editor.sizeToFit()
        editor.layoutSubtreeIfNeeded()

        // Scroll so the middle list item is centered in the viewport (content
        // above it, so the scroll origin is well past zero).
        let target = (editor.rawSource as NSString).range(of: "list item beta").location
        guard let lineY = editor.lineRect(forCharacterAt: target)?.midY else {
            Issue.record("no line rect for the list item"); return
        }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, lineY - 150)))
        scroll.reflectScrolledClipView(scroll.contentView)
        let yBefore = scroll.contentView.bounds.origin.y
        #expect(yBefore > 0)

        // Put the caret in the list item and indent it.
        editor.setSelectedRange(NSRange(location: target, length: 0))
        editor.insertTab(nil)
        #expect(editor.rawSource.contains("  - list item beta"))

        ensureFullLayout(editor)
        editor.layoutSubtreeIfNeeded()
        let yAfter = scroll.contentView.bounds.origin.y
        #expect(abs(yAfter - yBefore) < 2.0,
                "scroll lurched by \(yAfter - yBefore) on Tab indent")
    }

    /// A scrolled editor with content above the viewport, ready for the
    /// whole-document refreshes below.
    @MainActor private func scrolledEditor() -> (EditorTextView, NSScrollView) {
        let editor = makeEditor()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                           styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: win.contentLayoutRect)
        scroll.documentView = editor
        win.contentView = scroll
        win.makeFirstResponder(editor)
        editor.typewriterModeEnabled = false
        editor.isVerticallyResizable = true
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]

        var doc = ""
        // Headings and callouts, so the styled heights differ from the base
        // estimates the invalidation falls back to — that gap is the bug.
        for i in 0..<120 {
            if i % 10 == 0 { doc += "## Section \(i)\n\n" }
            doc += "paragraph number \(i) with enough text on it to wrap once\n\n"
        }
        editor.loadContent(doc)
        ensureFullLayout(editor); drainAllStyling(editor)
        editor.sizeToFit(); editor.layoutSubtreeIfNeeded()

        let target = (editor.rawSource as NSString).range(of: "paragraph number 80").location
        guard let lineY = editor.lineRect(forCharacterAt: target)?.minY else { return (editor, scroll) }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: lineY))
        scroll.reflectScrolledClipView(scroll.contentView)
        return (editor, scroll)
    }

    // Both refreshes throw away layout for the WHOLE document, dropping every
    // fragment back to a height estimate. Unanchored, the content above the
    // viewport re-measures and the same clip origin lands elsewhere: measured
    // at +64 lines on a 2000-line file when the appearance switched.

    @Test("A whole-document restyle (appearance/theme) keeps the viewport put")
    @MainActor func rerenderStylesKeepsViewport() {
        let (editor, _) = scrolledEditor()
        let before = editor.topmostVisibleCharacterOffset()
        #expect(before ?? 0 > 0)

        editor.rerenderStyles()
        // The app's own settle, not a raw `ensureFullLayout`: correcting the
        // estimates is what moves the content, and the settle is the thing that
        // is supposed to compensate for it.
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        editor.layoutSubtreeIfNeeded()

        #expect(editor.topmostVisibleCharacterOffset() == before,
                "top line moved from \(before ?? -1) to \(editor.topmostVisibleCharacterOffset() ?? -1)")
    }

    @Test("A draw-only setting toggle (focus, invisibles) keeps the viewport put")
    @MainActor func refreshOverdrawKeepsViewport() {
        let (editor, _) = scrolledEditor()
        let before = editor.topmostVisibleCharacterOffset()
        #expect(before ?? 0 > 0)

        editor.focusMode = true
        editor.refreshOverdraw()
        // The app's own settle, not a raw `ensureFullLayout`: correcting the
        // estimates is what moves the content, and the settle is the thing that
        // is supposed to compensate for it.
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        editor.layoutSubtreeIfNeeded()

        #expect(editor.topmostVisibleCharacterOffset() == before,
                "top line moved from \(before ?? -1) to \(editor.topmostVisibleCharacterOffset() ?? -1)")
    }

    // Narrowing the text re-wraps every paragraph, so the content above the
    // viewport changes height — the same drift as a whole-document restyle,
    // reached through the column width instead. Both settings are reachable
    // live: the Appearance pane's width slider (and zoom), and Settings ▸ Edit.

    @Test("Narrowing the content column keeps the viewport put")
    @MainActor func maxContentWidthKeepsViewport() {
        let (editor, _) = scrolledEditor()
        let before = editor.topmostVisibleCharacterOffset()
        #expect(before ?? 0 > 0)

        editor.maxContentWidthPoints = 260
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        editor.layoutSubtreeIfNeeded()

        #expect(editor.topmostVisibleCharacterOffset() == before,
                "top line moved from \(before ?? -1) to \(editor.topmostVisibleCharacterOffset() ?? -1)")
    }

    @Test("Turning on line numbers keeps the viewport put")
    @MainActor func lineNumbersKeepViewport() {
        let (editor, _) = scrolledEditor()
        let before = editor.topmostVisibleCharacterOffset()
        #expect(before ?? 0 > 0)

        editor.showLineNumbers = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        editor.layoutSubtreeIfNeeded()

        #expect(editor.topmostVisibleCharacterOffset() == before,
                "top line moved from \(before ?? -1) to \(editor.topmostVisibleCharacterOffset() ?? -1)")
    }
}
