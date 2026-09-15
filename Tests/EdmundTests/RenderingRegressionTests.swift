import Testing
import AppKit
@testable import EdmundCore

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

    @Test("Inline math line reserves the equation's height (ascent + descent)")
    @MainActor func inlineMathReservesLineHeight() {
        let editor = makeEditor()
        // A heading line that wraps the equation onto the same logical line.
        let styled = editor.styleBlock("## Heading $\\frac{a}{b}+x^2$")
        // The overlay and its ascent/descent split.
        var overlay: FragmentOverlay?
        styled.enumerateAttribute(.fragmentOverlay,
                                  in: NSRange(location: 0, length: styled.length)) { v, _, _ in
            if let o = v as? FragmentOverlay { overlay = o }
        }
        let o = try! #require(overlay)
        let descent = -o.bounds.minY
        let ascent = o.bounds.height - descent
        #expect(o.bounds.height > 0)
        // The math line reserves ascent as its line height and folds descent into
        // trailing spacing — together they cover the full image so the tall
        // equation can't overlap the lines around it. (Reserving the full height
        // as minimumLineHeight would pin the baseline at the box bottom and let
        // the descent overlap the next line.)
        let mathLoc = (styled.string as NSString).range(of: "$").location
        let ps = styled.attribute(.paragraphStyle, at: mathLoc, effectiveRange: nil) as? NSParagraphStyle
        #expect((ps?.minimumLineHeight ?? 0) >= ascent - 0.5, "line height must reserve the ascent")
        #expect((ps?.paragraphSpacing ?? 0) >= descent - 0.5, "trailing spacing must reserve the descent")
    }

    // MARK: Full-width image doesn't double its reserved height

    /// Writes a square solid PNG wider than any reasonable text column, so the
    /// image renderer scales it down to exactly fill the available width.
    private func tempWidePNGPath() -> String {
        let size = NSSize(width: 2000, height: 2000)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(origin: .zero, size: size).fill()
        img.unlockFocus()
        let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
        let data = rep.representation(using: .png, properties: [:])!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("md-wide-img-test-\(UUID().uuidString).png")
        try! data.write(to: url)
        return url.path
    }

    @Test("A full-width image's hidden markdown doesn't wrap onto a second, needlessly tall line")
    @MainActor func fullWidthImageNoDoubleHeight() {
        let path = tempWidePNGPath()
        let doc = "![alt](\(path))\n# Next"
        let (e, _) = windowed(doc)
        // Move the cursor off the image block so it renders the overlay
        // (not the raw, active markdown).
        e.setSelectedRange(NSRange(location: (doc as NSString).length, length: 0))
        e.recomposeIncremental(cursorInRaw: (doc as NSString).length)
        ensureFullLayout(e); drainAllStyling(e)
        e.sizeToFit(); e.layoutSubtreeIfNeeded(); ensureFullLayout(e)

        guard let overlay = e.imageOverlay(destination: path) else {
            Issue.record("expected an overlay for the wide image")
            return
        }
        guard let tlm = e.textLayoutManager else { Issue.record("no text layout manager"); return }
        var imageFragmentHeight: CGFloat?
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: []) { frag in
            if imageFragmentHeight == nil, frag.textLineFragments.count >= 1,
               frag.layoutFragmentFrame.height >= overlay.bounds.height {
                imageFragmentHeight = frag.layoutFragmentFrame.height
                #expect(frag.textLineFragments.count == 1,
                        "the hidden markdown after the image anchor must fit on the image's own line")
            }
            return true
        }
        #expect(imageFragmentHeight != nil)
        #expect((imageFragmentHeight ?? 0) < overlay.bounds.height * 1.5,
                "the image's fragment must not double-reserve height for a phantom wrapped line")
    }

    @Test("Display math still reserves enough room for its equation image")
    @MainActor func displayMathReservesHeight() {
        let editor = makeEditor()
        let styled = editor.styleBlock("$$\n\\frac{a}{b}\n$$")
        var overlayH: CGFloat = 0
        styled.enumerateAttribute(.fragmentOverlay,
                                  in: NSRange(location: 0, length: styled.length)) { v, _, _ in
            if let o = v as? FragmentOverlay { overlayH = max(overlayH, o.bounds.height) }
        }
        #expect(overlayH > 0)
        let ps = styled.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        // The image's ascent is reserved as the line's own height and its
        // descent is folded into the trailing spacing instead (see
        // MathRenderingTests' "Tall multi-row display math..." for why a tall,
        // descent-heavy equation can't reserve its *whole* height as
        // minimumLineHeight without leaving a gap above it) — together they
        // must still cover the whole image so it can't overlap what follows.
        let reserved = (ps?.minimumLineHeight ?? 0) + (ps?.paragraphSpacing ?? 0)
        #expect(reserved >= overlayH - 0.5,
                "combined line height + trailing spacing must cover the equation image")
    }

    // MARK: Thematic break — symmetric breathing space

    @Test("Thematic break rule is drawn equidistant from the text above and below")
    @MainActor func thematicBreakBalanced() {
        // `***` not `---`: a `---` directly under a paragraph is a setext h2
        // underline (GFM), not a rule.
        let (e, _) = windowed("Text line above the rule.\n***\nText line below the rule.")
        guard let tlm = e.textLayoutManager else { Issue.record("no tlm"); return }

        // Collect the three fragments: text, rule, text.
        var frags: [NSTextLayoutFragment] = []
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: []) {
            frags.append($0); return frags.count < 3
        }
        #expect(frags.count == 3)
        let (above, rule, below) = (frags[0], frags[1], frags[2])

        // The rule's drawn Y = fragment center + the compensating offset.
        let ruleY = rule.layoutFragmentFrame.midY + e.thematicBreakCenterOffset

        // Glyph edges of the neighbouring text (container coordinates): the
        // baseline of the line above, and the cap-top of the line below.
        func baseline(_ f: NSTextLayoutFragment) -> CGFloat? {
            guard let line = f.textLineFragments.first else { return nil }
            return f.layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y
        }
        guard let aboveBaseline = baseline(above),
              let belowLine = below.textLineFragments.first else {
            Issue.record("missing line metrics"); return
        }
        let belowTop = below.layoutFragmentFrame.minY + belowLine.typographicBounds.minY
            + belowLine.glyphOrigin.y - e.bodyFont.capHeight

        let gapAbove = ruleY - aboveBaseline
        let gapBelow = belowTop - ruleY
        #expect(abs(gapAbove - gapBelow) < 4.0,
                "rule must sit between the text lines (above=\(gapAbove), below=\(gapBelow))")
    }

    // MARK: Read mode's CSS line-height matches Edit mode's real line pitch

    /// Read mode used to hardcode the body font's natural line height as 1.2×,
    /// which is wrong for the default face (Iowan Old Style is 1.365×) — so every
    /// Read-mode line came out ~11% tighter than the editor's, and the font-size
    /// stepper moved the two modes apart instead of together. Measure the editor's
    /// actual line pitch and hold the emitted CSS to it.
    @Test("CSS --line-height equals the editor's measured line pitch")
    @MainActor func cssLineHeightMatchesEditorLinePitch() {
        // One paragraph long enough to wrap: successive line-fragment origins
        // inside a single layout fragment give the true pitch (natural line
        // height + the paragraph style's lineSpacing) with no ambiguity about
        // whether typographicBounds already folds lineSpacing in.
        let (e, _) = windowed(String(repeating: "wrapping body text ", count: 40))
        guard let tlm = e.textLayoutManager else { Issue.record("no tlm"); return }

        var first: NSTextLayoutFragment?
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: []) {
            first = $0; return false
        }
        guard let frag = first, frag.textLineFragments.count >= 2 else {
            Issue.record("paragraph did not wrap"); return
        }
        let origins = frag.textLineFragments.map { $0.typographicBounds.minY }
        let pitch = origins[1] - origins[0]

        // The same theme the editor is rendering with, through the Read-mode CSS.
        let css = HTMLTheme.css(e.theme, callouts: Callout.defaultStyles, dark: false)
        guard let range = css.range(of: "--line-height: "),
              let end = css[range.upperBound...].firstIndex(of: ";"),
              let cssLineHeight = Double(css[range.upperBound..<end]) else {
            Issue.record("no --line-height in emitted CSS"); return
        }
        let cssPitch = CGFloat(cssLineHeight) * e.theme.fontSize

        // Tight on purpose: the two are the same number by construction now, so
        // any real drift (a changed metric, a reintroduced constant) shows up.
        #expect(abs(cssPitch - pitch) < 0.05,
                "Read mode line pitch \(cssPitch)pt must match Edit mode's \(pitch)pt")
    }

    /// The same equality, for a face whose two candidate metrics disagree sharply
    /// (Helvetica: defaultLineHeight 19.0 vs ascender−descender+leading 16.0).
    /// Iowan alone cannot tell the two formulas apart — they differ by 0.7% there.
    @Test("CSS line-height tracks the editor for a font with unusual metrics")
    @MainActor func cssLineHeightMatchesForHelvetica() {
        let e = makeEditor()
        var theme = e.theme
        theme.fontName = "Helvetica"
        e.theme = theme
        e.textContainerInset = NSSize(width: 24, height: 18)
        e.loadContent(String(repeating: "wrapping body text ", count: 40))
        ensureFullLayout(e); drainAllStyling(e); e.sizeToFit(); ensureFullLayout(e)

        guard let tlm = e.textLayoutManager else { Issue.record("no tlm"); return }
        var first: NSTextLayoutFragment?
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: []) {
            first = $0; return false
        }
        guard let frag = first, frag.textLineFragments.count >= 2 else {
            Issue.record("paragraph did not wrap"); return
        }
        let origins = frag.textLineFragments.map { $0.typographicBounds.minY }
        let pitch = origins[1] - origins[0]

        let css = HTMLTheme.css(theme, callouts: Callout.defaultStyles, dark: false)
        guard let range = css.range(of: "--line-height: "),
              let end = css[range.upperBound...].firstIndex(of: ";"),
              let cssLineHeight = Double(css[range.upperBound..<end]) else {
            Issue.record("no --line-height in emitted CSS"); return
        }
        #expect(abs(CGFloat(cssLineHeight) * theme.fontSize - pitch) < 0.05,
                "Helvetica: CSS pitch \(CGFloat(cssLineHeight) * theme.fontSize)pt vs editor \(pitch)pt")
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

    // MARK: Cursor move while scrolled away doesn't yank the viewport

    @Test("A cross-block cursor move defers the off-screen old block instead of restyling it")
    @MainActor func offscreenOldActiveDeferred() {
        // Varied heights so deactivating a far-off block would change a lot of
        // height (the source of the old viewport yank).
        var doc = ""
        for i in 0..<300 {
            switch i % 3 {
            case 0: doc += "> [!note]\n> callout \(i)\n> body line\n\n"
            case 1: doc += "# Heading number \(i)\n\n"
            default: doc += "paragraph number \(i) with some words\n\n"
            }
        }
        let (e, scroll) = windowed(doc)
        e.typewriterModeEnabled = false

        // Activate a block near the top, then scroll far away from it.
        let topBlock = 4
        let topLoc = e.blocks[topBlock].range.location
        e.setSelectedRange(NSRange(location: topLoc, length: 0))
        e.recomposeIncremental(cursorInRaw: topLoc)
        #expect(e.activeBlockIndex == topBlock)

        scroll.contentView.scroll(to: NSPoint(x: 0, y: e.frame.height / 2))
        scroll.reflectScrolledClipView(scroll.contentView)
        e.promoteVisibleUnstyledBlocks()
        let before = scroll.contentView.bounds.origin.y

        // Move the caret to a visible block in the middle (the old active block
        // is now far off screen above). This goes through the same dirty-set
        // logic the async selection handler uses.
        let midBlock = e.blockIndexForRawOffset(Int(before) / 20 + 10) ?? topBlock
        let newLoc = e.blocks[midBlock].range.location
        e.setSelectedRange(NSRange(location: newLoc, length: 0))

        var dirty = IndexSet([midBlock])
        // The off-screen old active block must be deferred (marked unstyled),
        // not added to the synchronous dirty set.
        let vis = e.syncStylingBlockRange()
        if let v = vis, v.contains(topBlock) { dirty.insert(topBlock) }
        else { e.blocks[topBlock].isStyled = false }
        e.recomposeDirty(dirty, cursorInRaw: newLoc)

        // The far-off old block was deferred, so the synchronous restyle didn't
        // change its (off-screen) height — the viewport must not have jumped.
        let after = scroll.contentView.bounds.origin.y
        #expect(e.blocks[topBlock].isStyled == false,
                "off-screen old active block should be deferred to the drain")
        #expect(abs(after - before) < 50, "viewport must not yank on a cross-block cursor move")
    }

    @Test("Activating a height-changing block keeps the viewport top pinned")
    @MainActor func viewportTopStableOnActivation() {
        // A document with a callout (rendered ↔ active height differs) sitting
        // below the top of the viewport.
        var doc = ""
        for i in 0..<30 { doc += "filler paragraph number \(i)\n\n" }
        doc += "> [!note]\n> callout body one\n> callout body two\n\n"
        for i in 0..<40 { doc += "trailing paragraph \(i)\n\n" }
        let (e, scroll) = windowed(doc)
        e.typewriterModeEnabled = false

        // Scroll so the callout is in view but NOT at the very top.
        let calloutIdx = e.blocks.firstIndex { if case .quoteRun = $0.kind { return true }; return false }!
        let cy = e.lineRect(forCharacterAt: e.blocks[calloutIdx].range.location)?.minY ?? 0
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, cy - 120)))
        scroll.reflectScrolledClipView(scroll.contentView)
        e.promoteVisibleUnstyledBlocks(); scroll.reflectScrolledClipView(scroll.contentView)

        // Screen position of the line at the top of the viewport.
        func topLineScreenY() -> CGFloat {
            let visible = scroll.contentView.bounds
            guard let tlm = e.textLayoutManager else { return 0 }
            let p = CGPoint(x: 0, y: visible.minY - e.textContainerOrigin.y)
            guard let frag = tlm.textLayoutFragment(for: p) else { return 0 }
            let off = tlm.offset(from: tlm.documentRange.location, to: frag.rangeInElement.location)
            return (e.lineRect(forCharacterAt: off)?.minY ?? 0) + e.textContainerOrigin.y - visible.origin.y
        }
        let before = topLineScreenY()

        // Activate the callout (height changes), via the viewport anchor path.
        let loc = e.blocks[calloutIdx].range.location + 2
        e.setSelectedRange(NSRange(location: loc, length: 0))
        e.preservingViewportAnchor {
            e.recomposeDirty(IndexSet([calloutIdx]), cursorInRaw: loc)
        }
        scroll.reflectScrolledClipView(scroll.contentView)
        let after = topLineScreenY()
        #expect(abs(after - before) < 6.0,
                "viewport top must stay pinned when a visible block changes height (Δ=\(after - before))")
    }

}

@Suite("Regression — separator attribute inheritance")
struct SeparatorInheritanceTests {

    /// A character inserted at a block boundary inherits its neighbor's
    /// attributes (TextKit typing semantics). When the neighbor is a
    /// display-math block, the inserted separator newline kept the centered
    /// paragraph style forever: no block's restyle covers separators, so
    /// only a full recompose would clear it. restyleBlock now resets the
    /// separators adjacent to every block it styles.
    @Test("Newline inserted at a $$ block boundary doesn't keep centered style")
    @MainActor func insertAtMathBoundary() {
        let doc = "$$\nx = 1\n$$\n\n$$\ny_{1} = 2\n$$"
        let len = (doc as NSString).length
        for loc in 0...len {
            let editor = makeEditor()
            editor.loadContent(doc)
            editor.setSelectedRange(NSRange(location: loc, length: 0))
            editor.insertText("\n", replacementRange: NSRange(location: loc, length: 0))
            assertMatchesFullRecomposeOracle(editor, "insert at \(loc)")
        }
    }
}
