import Testing
import AppKit
@testable import MarkdownEditorCore

/// Regressions from the TextKit 2 / fragment-overlay migration.
@Suite("Rendering regressions (TextKit 2)")
struct RenderingRegressionTests {

    @MainActor private func windowed(_ doc: String, h: CGFloat = 400)
        -> (EditorTextView, NSScrollView) {
        let e = makeEditor()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: h),
                           styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: win.contentLayoutRect)
        scroll.documentView = e
        win.contentView = scroll
        win.makeFirstResponder(e)
        e.isVerticallyResizable = true
        e.minSize = NSSize(width: 0, height: 0)
        e.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                           height: CGFloat.greatestFiniteMagnitude)
        e.autoresizingMask = [.width]
        e.textContainerInset = NSSize(width: 24, height: 18)
        e.loadContent(doc)
        ensureFullLayout(e); drainAllStyling(e)
        e.sizeToFit(); e.layoutSubtreeIfNeeded(); ensureFullLayout(e)
        return (e, scroll)
    }

    // MARK: Inline math reserves line height (no overlap with the next line)

    @Test("Inline math line is tall enough for the equation image")
    @MainActor func inlineMathReservesLineHeight() {
        let editor = makeEditor()
        // A heading line that wraps the equation onto the same logical line.
        let styled = editor.styleBlock("## Heading $\\frac{a}{b}+x^2$")
        // The overlay's image height.
        var overlayH: CGFloat = 0
        styled.enumerateAttribute(.fragmentOverlay,
                                  in: NSRange(location: 0, length: styled.length)) { v, _, _ in
            if let o = v as? FragmentOverlay { overlayH = max(overlayH, o.bounds.height) }
        }
        #expect(overlayH > 0)
        // The paragraph style on the math line must reserve at least the image
        // height (so the tall equation can't overlap the following line).
        let mathLoc = (styled.string as NSString).range(of: "$").location
        let ps = styled.attribute(.paragraphStyle, at: mathLoc, effectiveRange: nil) as? NSParagraphStyle
        #expect((ps?.minimumLineHeight ?? 0) >= overlayH - 0.5,
                "inline math line must reserve the equation's height")
    }

    @Test("Display math still reserves its own line height")
    @MainActor func displayMathReservesHeight() {
        let editor = makeEditor()
        let styled = editor.styleBlock("$$\n\\frac{a}{b}\n$$")
        var overlayH: CGFloat = 0
        styled.enumerateAttribute(.fragmentOverlay,
                                  in: NSRange(location: 0, length: styled.length)) { v, _, _ in
            if let o = v as? FragmentOverlay { overlayH = max(overlayH, o.bounds.height) }
        }
        let ps = styled.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect((ps?.minimumLineHeight ?? 0) >= overlayH - 0.5)
    }

    // MARK: Thematic break — symmetric breathing space

    @Test("Thematic break uses symmetric paragraph spacing")
    @MainActor func thematicBreakSymmetric() {
        let editor = makeEditor()
        let styled = editor.styleBlock("---")
        let ps = styled.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(ps != nil)
        #expect(abs((ps?.paragraphSpacingBefore ?? 0) - (ps?.paragraphSpacing ?? 0)) < 0.01,
                "the rule's breathing space must be symmetric so it sits centered")
    }

    // MARK: Scroll targets accurate under lazy layout

    @Test("The drain styling blocks above the viewport does not shift visible content")
    @MainActor func drainDoesNotJumpViewport() {
        // Varied heights so styling a block above the viewport changes its
        // height meaningfully (heading scale, callout box, display-math).
        var doc = ""
        for i in 0..<400 {
            switch i % 4 {
            case 0: doc += "# Heading number \(i)\n\n"
            case 1: doc += "> [!note]\n> callout \(i)\n> body line\n\n"
            case 2: doc += "$$\n\\frac{a}{b}=\(i)\n$$\n\n"
            default: doc += "plain paragraph number \(i)\n\n"
            }
        }
        let (e, scroll) = windowed(doc)
        e.typewriterModeEnabled = false

        // Scroll to the middle (blocks above are styled by promotion; the deep
        // tail and any gaps remain to be drained).
        scroll.contentView.scroll(to: NSPoint(x: 0, y: e.frame.height / 2))
        scroll.reflectScrolledClipView(scroll.contentView)
        e.promoteVisibleUnstyledBlocks()
        scroll.reflectScrolledClipView(scroll.contentView)

        // Record the screen Y of a block sitting in the viewport.
        let visible = scroll.contentView.bounds
        var anchor: Int? = nil
        for idx in e.blocks.indices {
            if let r = e.lineRect(forCharacterAt: e.blocks[idx].range.location) {
                let y = r.minY + e.textContainerOrigin.y
                if y > visible.minY + 60 && y < visible.maxY - 60 { anchor = idx; break }
            }
        }
        guard let anchor else { Issue.record("no visible anchor block"); return }
        func screenY() -> CGFloat {
            (e.lineRect(forCharacterAt: e.blocks[anchor].range.location)?.minY ?? 0)
                + e.textContainerOrigin.y - scroll.contentView.bounds.origin.y
        }
        let before = screenY()

        // Drain everything (styles blocks above and below the viewport).
        drainAllStyling(e)
        scroll.reflectScrolledClipView(scroll.contentView)

        let after = screenY()
        #expect(abs(after - before) < 8.0,
                "drain styling must not jump the viewport (Δ=\(after - before))")
    }

    @Test("Moving the caret to an already-visible line does not scroll")
    @MainActor func smallMoveNoScroll() {
        var doc = ""
        for i in 0..<300 { doc += "line number \(i) with text\n\n" }
        let (e, scroll) = windowed(doc)
        e.typewriterModeEnabled = false

        let midY = e.frame.height / 2
        scroll.contentView.scroll(to: NSPoint(x: 0, y: midY))
        scroll.reflectScrolledClipView(scroll.contentView)
        e.promoteVisibleUnstyledBlocks()
        scroll.reflectScrolledClipView(scroll.contentView)

        // Find a block whose line is comfortably inside the viewport.
        let visible = scroll.contentView.bounds
        var visibleBlock: Int? = nil
        for idx in e.blocks.indices {
            if let r = e.lineRect(forCharacterAt: e.blocks[idx].range.location) {
                let y = r.minY + e.textContainerOrigin.y
                if y > visible.minY + 40 && y < visible.maxY - 40 { visibleBlock = idx; break }
            }
        }
        guard let vb = visibleBlock else { Issue.record("no visible block found"); return }

        let loc = e.blocks[vb].range.location
        let before = scroll.contentView.bounds.origin.y
        e.setSelectedRange(NSRange(location: loc, length: 0))
        e.scrollRangeToVisible(NSRange(location: loc, length: 0))
        let after = scroll.contentView.bounds.origin.y
        #expect(abs(after - before) < 2.0, "moving to an already-visible line must not scroll")
    }
}
