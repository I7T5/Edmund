// Focus mode: the lines the selection touches stay at full strength, everything
// else fades. A pure display effect — no characters, attributes or colors
// change, so storage stays == rawSource and nothing is restyled when the caret
// moves. Editor-only; Read mode never dims.
//
// The fade happens inside `DecoratedTextLayoutFragment.draw`, wrapping the
// fragment's whole body — text *and* the things drawn around it: code-block and
// callout boxes, quote bars, table borders, list guides, math and bullet
// overlays. That is the point: those are baked into `BlockDecoration` /
// `FragmentOverlay` values (and cached images), so fading them through color
// attributes would mean recomputing decorations and regenerating overlays on
// every caret move. One transparency layer fades all of it at once, and fading
// a pixel toward an opaque background is the same result as lerping its color
// toward that background anyway.
//
// It cannot be a scrim painted over the text by the text view: NSTextView
// composites TextKit 2 fragments *after* its own `draw(_:)` returns, so a fill
// there lands under the glyphs and under every box (measured — a code block
// drew clean over a full-view test fill).

import AppKit

extension EditorTextView {
    /// What unfocused content fades to. 1 = no dim, 0 = invisible.
    nonisolated public static let focusDimOpacity: CGFloat = 0.35
}

extension DecoratedTextLayoutFragment {

    /// Whether this fragment is one focus mode fades. One text element is one
    /// source line, so "the caret's line" is just "this element holds part of a
    /// selection".
    ///
    /// The setting is read from the editor at draw time, not captured at vend
    /// time: the layout manager caches its fragments, and `invalidateLayout`
    /// alone doesn't re-vend them (measured), so a captured flag would keep
    /// dimming after the mode was switched off.
    var dimmedByFocus: Bool {
        guard owner?.focusMode == true else { return false }
        return !isFocused
    }

    /// True when any selection touches this element. Read from the fragment's
    /// own layout manager at draw time — same trick as the invisibles overdraw,
    /// and the reason a caret move needs no restyle and no re-vend.
    private var isFocused: Bool {
        guard let tlm = textLayoutManager, let range = textElement?.elementRange
        else { return false }
        for selection in tlm.textSelections {
            for selected in selection.textRanges {
                if selected.isEmpty {
                    // A caret sits *in* the line whose range contains it. At the
                    // very end of a document with no trailing newline there is no
                    // such line — the location is every range's exclusive end —
                    // so the last line claims it.
                    if range.contains(selected.location) { return true }
                    let caret = selected.location
                    if caret.compare(tlm.documentRange.endLocation) == .orderedSame,
                       range.endLocation.compare(caret) == .orderedSame { return true }
                } else if selected.intersects(range) {
                    // A selection ending exactly at this line's start stops
                    // short of it: `intersects` is half-open, so touching ranges
                    // don't count — the same rule the line-number highlight uses.
                    return true
                }
            }
        }
        return false
    }

    /// Opens a transparency layer that fades everything drawn until
    /// `endFocusDim`. A layer rather than a bare `setAlpha` so overlapping draws
    /// (a code box, then its text) fade as one composite instead of compounding.
    /// Returns whether anything was opened.
    func beginFocusDim(in context: CGContext) -> Bool {
        guard dimmedByFocus else { return false }
        context.saveGState()
        context.setAlpha(EditorTextView.focusDimOpacity)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        return true
    }

    func endFocusDim(_ opened: Bool, in context: CGContext) {
        guard opened else { return }
        context.endTransparencyLayer()
        context.restoreGState()
    }
}
