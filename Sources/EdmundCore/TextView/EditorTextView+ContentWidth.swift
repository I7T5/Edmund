import AppKit

// MARK: - Content width (centered reading column)
//
// The text column has a physical maximum width (set in cm in Settings and
// converted to points using the display's real PPI). Windows wider than the
// cap get symmetric side margins that center the column; narrower windows
// fill edge-to-edge as usual. This is CSS `max-width` semantics: the cap is
// an absolute physical size, not a fraction of the window or the screen, so
// the column doesn't widen when you make the window bigger.

extension EditorTextView {

    /// Padding applied on each side of the text column at all window sizes.
    static let contentBaseInset: CGFloat = 24

    /// The symmetric horizontal inset for a given view width and max-column width.
    /// `maxContentWidth == .greatestFiniteMagnitude` → base inset only (fills the window).
    /// When the window is too narrow to fit `maxContentWidth`, the column also fills.
    public static func horizontalInset(viewWidth: CGFloat, maxContentWidth: CGFloat) -> CGFloat {
        let available = viewWidth - 2 * contentBaseInset
        guard available > maxContentWidth else { return contentBaseInset }
        return contentBaseInset + (available - maxContentWidth) / 2
    }

    /// Recomputes the horizontal text inset from the current bounds + max-column cap,
    /// preserving the vertical inset. Cheap (no recompose) — only the inset changes.
    public func updateContentInset() {
        let target = Self.horizontalInset(viewWidth: bounds.width,
                                          maxContentWidth: maxContentWidthPoints)
        if abs(textContainerInset.width - target) > 0.5 {
            textContainerInset = NSSize(width: target, height: textContainerInset.height)
        }
    }

    /// Sets the max-column width (in points) and applies it immediately.
    /// Called from the Settings broadcast and the screen-change observer.
    public func applyContentWidth(_ points: CGFloat) {
        maxContentWidthPoints = points
    }

    /// Recompute the centered inset as the view width changes (window resize).
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateContentInset()
    }
}
