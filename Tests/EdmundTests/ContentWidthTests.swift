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

    @Test("contentCoverage: fraction 1 ≈ whole screen; fraction 0 is the floor share")
    func coverage() {
        let w: CGFloat = 1512
        let full = EditorTextView.contentCoverage(viewWidth: w, fraction: 1)
        let mobile = EditorTextView.contentCoverage(viewWidth: w, fraction: 0)
        // Full = the whole width minus the base inset on each side.
        #expect(abs(full - (w - 2 * base) / w) < 0.001)
        // Mobile = the fixed minimum column as a share of the screen (never 0).
        #expect(abs(mobile - minW / w) < 0.001)
        #expect(mobile > 0.2 && full < 1.0 && full > mobile)
    }

    @Test("fraction(forCoverage:) inverts contentCoverage")
    func coverageRoundTrip() {
        let w: CGFloat = 1512
        for tenth in 0...10 {
            let f = CGFloat(tenth) / 10
            let cov = EditorTextView.contentCoverage(viewWidth: w, fraction: f)
            let back = EditorTextView.fraction(forCoverage: cov, viewWidth: w)
            #expect(abs(back - f) < 0.001)
        }
    }

    @Test("Narrow windows just fill (base inset)")
    func narrowFills() {
        // Available width below the minimum column → no room to center; fill.
        let inset = EditorTextView.horizontalInset(viewWidth: minW + 2 * base - 10, fraction: 0.3)
        #expect(abs(inset - base) < 0.01)
    }
}
