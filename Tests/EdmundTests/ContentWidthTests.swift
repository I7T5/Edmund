import Testing
import AppKit
@testable import EdmundCore

/// The centered reading-column math: `horizontalInset` turns a width + fraction
/// into a symmetric text inset. Pins the endpoints and the clamps.
@Suite("Content width")
@MainActor
struct ContentWidthTests {

    let base = EditorTextView.contentBaseInset      // 24
    let minW = EditorTextView.contentMinWidth       // 380

    @Test("Fraction 1 fills the width (base inset only)")
    func fullWidth() {
        let inset = EditorTextView.horizontalInset(viewWidth: 1400, fraction: 1)
        #expect(abs(inset - base) < 0.01)
    }

    @Test("Fraction 0 yields the minimum centered column")
    func minColumn() {
        let viewWidth: CGFloat = 1400
        let inset = EditorTextView.horizontalInset(viewWidth: viewWidth, fraction: 0)
        let available = viewWidth - 2 * base
        let expected = base + (available - minW) / 2
        #expect(abs(inset - expected) < 0.01)
        // The resulting column is exactly the minimum width.
        let column = viewWidth - 2 * inset
        #expect(abs(column - minW) < 0.01)
    }

    @Test("Lower fraction means wider margins")
    func monotonic() {
        let w: CGFloat = 1400
        let i100 = EditorTextView.horizontalInset(viewWidth: w, fraction: 1)
        let i60 = EditorTextView.horizontalInset(viewWidth: w, fraction: 0.6)
        let i20 = EditorTextView.horizontalInset(viewWidth: w, fraction: 0.2)
        #expect(i100 < i60)
        #expect(i60 < i20)
    }

    @Test("Margins grow with window width at a fixed fraction")
    func widerWindowMoreMargin() {
        let narrow = EditorTextView.horizontalInset(viewWidth: 800, fraction: 0.6)
        let wide = EditorTextView.horizontalInset(viewWidth: 1600, fraction: 0.6)
        #expect(wide > narrow)
    }

    @Test("Narrow windows just fill (base inset)")
    func narrowFills() {
        // Available width below the minimum column → no room to center; fill.
        let inset = EditorTextView.horizontalInset(viewWidth: minW + 2 * base - 10, fraction: 0.3)
        #expect(abs(inset - base) < 0.01)
    }
}
