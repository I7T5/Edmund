import AppKit

// MARK: - Content width (centered reading column)
//
// The text column can be narrowed to a fraction of the available width and
// centered, so wide/full-screen windows get readable side margins instead of
// edge-to-edge lines. The fraction is a symmetric `textContainerInset.width`,
// recomputed whenever the fraction or the view width changes.

extension EditorTextView {

    /// The minimum text-column width (a comfortable mobile-ish reading measure)
    /// the slider's low end maps to, and the base inset kept at full width.
    static let contentMinWidth: CGFloat = 380
    static let contentBaseInset: CGFloat = 24

    /// The symmetric horizontal inset for a given view width and fraction.
    /// `fraction == 1` → just the base inset (fills the width, today's look);
    /// lower fractions interpolate the column down to `contentMinWidth`, the
    /// remaining space split into equal left/right margins. Narrow windows
    /// (where even the minimum column won't fit past the base inset) just fill.
    static func horizontalInset(viewWidth: CGFloat, fraction: CGFloat) -> CGFloat {
        let available = viewWidth - 2 * contentBaseInset
        guard available > contentMinWidth else { return contentBaseInset }
        let f = min(1, max(0, fraction))
        let column = min(available, max(contentMinWidth,
                                        contentMinWidth + f * (available - contentMinWidth)))
        return contentBaseInset + (available - column) / 2
    }

    /// The fraction of `viewWidth` the text column actually occupies for a given
    /// `fraction` — i.e. how much of the screen the content covers. The settings
    /// slider uses this to show a meaningful percentage (the column at its
    /// narrowest still covers a sizeable share of the screen, never 0%).
    public static func contentCoverage(viewWidth: CGFloat, fraction: CGFloat) -> CGFloat {
        guard viewWidth > 0 else { return 1 }
        let inset = horizontalInset(viewWidth: viewWidth, fraction: fraction)
        return (viewWidth - 2 * inset) / viewWidth
    }

    /// The inverse of `contentCoverage`: the `fraction` that makes the column
    /// cover `coverage` of `viewWidth`. Lets the settings stepper work in whole
    /// coverage-percent steps. Clamped to `0...1`.
    public static func fraction(forCoverage coverage: CGFloat, viewWidth: CGFloat) -> CGFloat {
        let available = viewWidth - 2 * contentBaseInset
        guard available > contentMinWidth else { return 1 }
        let column = coverage * viewWidth
        let f = (column - contentMinWidth) / (available - contentMinWidth)
        return min(1, max(0, f))
    }

    /// Recomputes the horizontal text inset from the current width + fraction,
    /// preserving the vertical inset. Cheap (no recompose) — only the inset and
    /// the resulting re-layout change.
    public func updateContentInset() {
        let target = Self.horizontalInset(viewWidth: bounds.width,
                                          fraction: contentWidthFraction)
        if abs(textContainerInset.width - target) > 0.5 {
            textContainerInset = NSSize(width: target, height: textContainerInset.height)
        }
    }

    /// Sets the column fraction and applies it immediately. Called from the
    /// Settings broadcast.
    public func applyContentWidth(_ fraction: CGFloat) {
        contentWidthFraction = fraction
    }

    /// Recompute the centered inset as the view width changes (window resize).
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateContentInset()
    }
}
