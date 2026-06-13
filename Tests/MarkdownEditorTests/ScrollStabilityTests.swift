import Testing
import AppKit
@testable import MarkdownEditorCore

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
}
