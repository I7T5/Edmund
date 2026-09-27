import Testing
import AppKit
@testable import EdmundCore

/// A callout's vertical padding is measured the way the eye reads it: box top
/// to the title's cap line, and the last line's baseline to the box bottom.
/// The bottom must exceed the top by `calloutBottomOpticalBias` for both header
/// kinds (default title drawn as an overlay image, custom title as live text)
/// and for a header-only callout. Matching ink box to ink box instead — icon
/// top vs descender bottom — left the bottom looking heavier.
@Suite("Callout padding — baseline bottom = cap-line top + bias")
struct CalloutPaddingGeometryTests {

    @MainActor private func windowed() -> EditorTextView {
        let e = makeEditor()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 800),
                           styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: win.contentLayoutRect)
        scroll.documentView = e
        win.contentView = scroll
        return e
    }

    /// Top (box top → title cap line) and bottom (last baseline → box bottom)
    /// gaps of the callout whose header paragraph starts at `headerLocation`.
    @MainActor private func gaps(_ e: EditorTextView, headerLocation: Int, lastLocation: Int)
        -> (top: CGFloat, bottom: CGFloat)? {
        guard let tlm = e.textLayoutManager, let tcm = tlm.textContentManager else { return nil }
        ensureFullLayout(e)
        func fragment(at offset: Int) -> NSTextLayoutFragment? {
            guard let loc = tcm.location(tcm.documentRange.location, offsetBy: offset) else { return nil }
            return tlm.textLayoutFragment(for: loc)
        }
        guard let header = fragment(at: headerLocation) as? DecoratedTextLayoutFragment,
              let last = fragment(at: lastLocation) as? DecoratedTextLayoutFragment,
              let headerLine = header.textLineFragments.first,
              let lastLine = last.textLineFragments.first else { return nil }
        let titleFont = NSFontManager.shared.convert(e.bodyFont, toHaveTrait: .boldFontMask)
        let headerBaseline = header.layoutFragmentFrame.minY
            + headerLine.typographicBounds.minY + headerLine.glyphOrigin.y
        let lastBaseline = last.layoutFragmentFrame.minY
            + lastLine.typographicBounds.minY + lastLine.glyphOrigin.y
        let boxBottom = last.layoutFragmentFrame.minY + last.decorationDrawHeight
        return (headerBaseline - titleFont.capHeight - header.layoutFragmentFrame.minY,
                boxBottom - lastBaseline)
    }

    @Test("Default and custom titles: bottom baseline gap = top cap gap + bias")
    @MainActor func bottomIsTopPlusBias() {
        let e = windowed()
        let doc = "Intro\n\n> [!note]\n> Body line.\n\nMid\n\n> [!tip] Custom title\n> Body line.\n\n"
            + "> [!warning]\n\nEnd"
        e.loadContent(doc)
        e.recompose(cursorInRaw: 0)
        let ns = doc as NSString
        let cases: [(header: String, last: String)] = [
            ("> [!note]", "> Body line.\n\nMid"),
            ("> [!tip]", "> Body line.\n\n> [!warning]"),
            ("> [!warning]", "> [!warning]"),   // header only: the header is the last line
        ]
        let bias = EditorTextView.calloutBottomOpticalBias
        for c in cases {
            let h = ns.range(of: c.header).location
            let l = ns.range(of: c.last).location
            guard let g = gaps(e, headerLocation: h, lastLocation: l) else {
                Issue.record("no fragments for \(c.header)"); continue
            }
            #expect(g.top > 0 && g.bottom > 0)
            #expect(abs(g.bottom - g.top - bias) < 0.5,
                    "\(c.header): bottom baseline gap \(g.bottom) should be top cap gap \(g.top) + \(bias)")
        }
    }

    /// Regression: TextKit drops `paragraphSpacingBefore` (and the line's
    /// `lineSpacing`) on the document's first paragraph, so a callout opening
    /// the document lost ~16pt of top padding.
    @Test("A callout opening the document keeps its top padding",
          arguments: ["> [!note]\n> Body line.", "> [!tip] Custom title\n> Body line."])
    @MainActor func documentStartKeepsTopPadding(callout: String) {
        let e = windowed()
        let doc = callout + "\n\nMid\n\n" + callout + "\n\nEnd"
        e.loadContent(doc)
        let ns = doc as NSString
        e.recompose(cursorInRaw: ns.range(of: "Mid").location)
        let second = ns.range(of: callout, options: .backwards).location
        let bodyOffset = (callout as NSString).range(of: "> Body").location
        guard let first = gaps(e, headerLocation: 0, lastLocation: bodyOffset),
              let mid = gaps(e, headerLocation: second, lastLocation: second + bodyOffset) else {
            Issue.record("no fragments"); return
        }
        #expect(abs(first.top - mid.top) < 0.5,
                "document-start top gap \(first.top) should match mid-document \(mid.top)")
    }
}
