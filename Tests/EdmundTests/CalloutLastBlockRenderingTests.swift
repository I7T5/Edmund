import Testing
import AppKit
@testable import EdmundCore

/// Regression: a callout that is the last block of a document that ends in a
/// newline must NOT paint its colored box over the trailing empty line.
///
/// TextKit 2 folds the document's final empty line (from the trailing "\n")
/// into the *preceding* layout fragment rather than giving it its own — it
/// appears as a trailing zero-length line fragment. The callout's last-line
/// `DecoratedTextLayoutFragment` then had its box fill the full frame height,
/// flooding the callout color onto that trailing line (the reported
/// "extra colored line at the bottom" bug, misc/bug-repros/
/// callout-extra-line-rendered-at-bottom.mov). The fill height must exclude
/// the absorbed empty line, so it matches the same callout without a trailing
/// newline.
@Suite("Callout as last block — no extra colored line")
struct CalloutLastBlockRenderingTests {

    @MainActor private func windowed() -> EditorTextView {
        let e = makeEditor()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 500),
                           styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: win.contentLayoutRect)
        scroll.documentView = e
        win.contentView = scroll
        win.makeFirstResponder(e)
        return e
    }

    /// The `DecoratedTextLayoutFragment` covering the last line of the document,
    /// with its full frame height and the height it actually fills.
    @MainActor private func lastDecoratedFragment(_ e: EditorTextView)
        -> (fill: CGFloat, frame: CGFloat, emptyTrailingLine: Bool)? {
        guard let tlm = e.textLayoutManager else { return nil }
        ensureFullLayout(e)
        var result: (CGFloat, CGFloat, Bool)?
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location,
                                         options: [.ensuresLayout]) { frag in
            if let d = frag as? DecoratedTextLayoutFragment {
                let hasEmptyTail = (frag.textLineFragments.count > 1)
                    && (frag.textLineFragments.last?.characterRange.length == 0)
                result = (d.decorationDrawHeight, d.layoutFragmentFrame.height, hasEmptyTail)
            }
            return true
        }
        return result
    }

    @Test("Box fill excludes the absorbed trailing empty line")
    @MainActor func trailingNewlineDoesNotExtendBox() {
        let withNL = windowed()
        withNL.loadContent("# H\n\n> [!tip] Short title\n> Body text here.\n")
        withNL.recompose(cursorInRaw: 0)
        guard let a = lastDecoratedFragment(withNL) else { Issue.record("no fragment"); return }

        let withoutNL = windowed()
        withoutNL.loadContent("# H\n\n> [!tip] Short title\n> Body text here.")
        withoutNL.recompose(cursorInRaw: 0)
        guard let b = lastDecoratedFragment(withoutNL) else { Issue.record("no fragment"); return }

        // The trailing-newline document really does absorb an empty line into
        // the callout fragment (frame taller than the no-newline case)...
        #expect(a.emptyTrailingLine == true)
        #expect(b.emptyTrailingLine == false)
        #expect(a.frame > b.frame)
        // ...but the box is DRAWN to the same height either way — the extra
        // empty line is not painted.
        #expect(abs(a.fill - b.fill) < 0.5,
                "box fill \(a.fill) (with trailing \\n) should match \(b.fill) (without)")
        #expect(a.fill < a.frame,
                "fill \(a.fill) must stop above the absorbed empty line (frame \(a.frame))")
    }
}
