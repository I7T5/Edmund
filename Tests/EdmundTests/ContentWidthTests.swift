import Testing
import AppKit
@testable import EdmundCore

/// The centered reading-column math: `horizontalInset` turns a view width and
/// a physical max-column cap into a symmetric text inset.
@Suite("Content width")
@MainActor
struct ContentWidthTests {

    let base = EditorTextView.contentBaseInset      // 24

    @Test("Window narrower than cap fills (base inset only)")
    func narrowFills() {
        let inset = EditorTextView.horizontalInset(viewWidth: 500, maxContentWidth: 600)
        #expect(abs(inset - base) < 0.01)
    }

    @Test("Window exactly at cap fills (available == cap, no room to center)")
    func exactFills() {
        let cap: CGFloat = 500
        let viewWidth = cap + 2 * base   // available == cap
        let inset = EditorTextView.horizontalInset(viewWidth: viewWidth, maxContentWidth: cap)
        #expect(abs(inset - base) < 0.01)
    }

    @Test("Wide window centers the column at the cap")
    func wideWindowCenters() {
        let cap: CGFloat = 600
        let viewWidth: CGFloat = 1200
        let inset = EditorTextView.horizontalInset(viewWidth: viewWidth, maxContentWidth: cap)
        let available = viewWidth - 2 * base
        let expected = base + (available - cap) / 2
        #expect(abs(inset - expected) < 0.01)
        // Column equals the cap exactly.
        #expect(abs((viewWidth - 2 * inset) - cap) < 0.01)
    }

    @Test("Larger cap means wider column (smaller inset)")
    func largerCapWiderColumn() {
        let viewWidth: CGFloat = 1400
        let insetNarrow = EditorTextView.horizontalInset(viewWidth: viewWidth, maxContentWidth: 400)
        let insetWide   = EditorTextView.horizontalInset(viewWidth: viewWidth, maxContentWidth: 800)
        #expect(insetNarrow > insetWide)
    }

    @Test("Infinite cap fills the window (base inset only)")
    func infiniteCapFills() {
        let inset = EditorTextView.horizontalInset(viewWidth: 1400, maxContentWidth: .greatestFiniteMagnitude)
        #expect(abs(inset - base) < 0.01)
    }

    @Test("Margins grow as window widens past the cap")
    func marginsGrowWithWindow() {
        let cap: CGFloat = 600
        let inset800  = EditorTextView.horizontalInset(viewWidth: 800,  maxContentWidth: cap)
        let inset1400 = EditorTextView.horizontalInset(viewWidth: 1400, maxContentWidth: cap)
        #expect(inset1400 > inset800)
    }

    @Test("Column stays pinned at cap regardless of window width")
    func columnPinnedAtCap() {
        let cap: CGFloat = 700
        for w: CGFloat in [800, 1000, 1400, 2000] {
            let inset = EditorTextView.horizontalInset(viewWidth: w, maxContentWidth: cap)
            let column = w - 2 * inset
            // Either filling (window too narrow) or exactly capped.
            let filling = w - 2 * base <= cap
            if filling {
                #expect(abs(inset - base) < 0.01)
            } else {
                #expect(abs(column - cap) < 0.01)
            }
        }
    }
}
