import AppKit

// MARK: - Table raw-editing button
//
// A `</>` affordance in the reading column's left margin, level with each
// table's header row. Clicking it puts the caret in the table, and the caret
// being in the table is what renders it as raw monospace markdown — the
// existing active-block behaviour. Clicking outside the table moves the caret
// out and renders it again, so "click outside to leave raw editing" needs no
// code of its own.
//
// It draws on the background pass beside the text, exactly like the line
// numbers, and never inside a layout fragment. Two things follow: it sits
// outside the reading column (beyond the max content width), and the
// image-wedge constraint on fragment overlays (ARCHITECTURE §4 — an image
// overlay wedges a wrapping fragment to one line) does not apply, so this can
// be a real SF Symbol rather than a stroked path.

extension EditorTextView {

    /// Side of the button's square draw/hit box.
    static let tableRawButtonSize: CGFloat = 13

    /// Gap between the button and whatever sits to its right.
    static let tableRawButtonGap: CGFloat = 8

    /// Left edge of the button box. It hangs in the margin just left of the
    /// text column, and steps left of the line numbers when those are sharing
    /// the same margin. Clamped to the view so a margin too tight to hold both
    /// shows the button at the window edge rather than off it — the numbers
    /// give way in that case anyway (`lineNumbersFitBesideContent`).
    static func tableRawButtonX(textStartX: CGFloat, reservedForLineNumbers: CGFloat) -> CGFloat {
        max(2, textStartX - tableRawButtonGap - reservedForLineNumbers - tableRawButtonSize)
    }

    /// Width the in-margin line numbers take out of the button's margin: zero
    /// unless they are actually drawn beside the text (off, or moved to the
    /// window-edge gutter, and they reserve nothing here).
    private var tableRawButtonReservedInset: CGFloat {
        guard showLineNumbers, lineNumberRuler == nil else { return 0 }
        return lineNumbersRequiredInset
    }

    /// The button box (view coordinates) and its block index, for every table
    /// whose header row is in the laid-out viewport.
    ///
    /// Walks the viewport the text view has already laid out, for the reason
    /// `enumerateVisibleLineNumbers` documents: forcing layout from inside a
    /// draw re-enters the viewport layout controller and blanks the view.
    func visibleTableRawButtons() -> [(rect: NSRect, blockIndex: Int)] {
        guard let tlm = textLayoutManager,
              let viewport = tlm.textViewportLayoutController.viewportRange else { return [] }
        // ponytail: rebuilt per draw rather than cached against `blocks` —
        // one pass over the block list, same order as the binary search the
        // line numbers already do per fragment. Cache it if a huge document
        // ever shows up in a scroll profile.
        var tableStarts: [Int: Int] = [:]
        for (i, block) in blocks.enumerated() where block.kind == .table {
            tableStarts[block.range.location] = i
        }
        guard !tableStarts.isEmpty else { return [] }

        let origin = textContainerOrigin
        let x = Self.tableRawButtonX(textStartX: origin.x + (textContainer?.lineFragmentPadding ?? 0),
                                     reservedForLineNumbers: tableRawButtonReservedInset)
        let size = Self.tableRawButtonSize
        let bottom = visibleRect.maxY - origin.y
        var result: [(rect: NSRect, blockIndex: Int)] = []

        tlm.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
            let frame = fragment.layoutFragmentFrame
            guard frame.minY <= bottom else { return false }
            let offset = tlm.offset(from: tlm.documentRange.location,
                                    to: fragment.rangeInElement.location)
            guard let blockIndex = tableStarts[offset],
                  let firstLine = fragment.textLineFragments.first else { return true }
            // Centre on the header row's cap band, not on its line box: the box
            // carries the table's leading paragraph spacing, so centring in it
            // rides high. Same correction the line numbers make.
            let baseline = frame.minY + firstLine.typographicBounds.minY + firstLine.glyphOrigin.y
            let capCenter = baseline - self.bodyFont.capHeight / 2
            result.append((NSRect(x: x, y: capCenter + origin.y - size / 2,
                                  width: size, height: size), blockIndex))
            return true
        }
        return result
    }

    /// Draws the `</>` buttons. Called from `drawBackground(in:)` — they occupy
    /// margin the text never uses, so nothing has to move to make room.
    func drawTableRawButtons(in rect: NSRect) {
        // ponytail: the symbol image is rebuilt per draw. It is one small
        // template image per visible table; give it a cache only if it shows up
        // in a scroll profile.
        guard let symbol = NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right",
                                   accessibilityDescription: "Edit table as Markdown") else { return }
        let configured = symbol.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: Self.tableRawButtonSize, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [syntaxDimColor])))
        guard let configured else { return }
        for (box, _) in visibleTableRawButtons() where box.intersects(rect) {
            // The symbol is wider than it is tall; fit it in the box by its own
            // aspect so the glyph isn't squashed into the square hit target.
            let drawn = configured.size
            let scale = min(box.width / drawn.width, box.height / drawn.height)
            let fitted = NSSize(width: drawn.width * scale, height: drawn.height * scale)
            configured.draw(in: NSRect(x: box.midX - fitted.width / 2,
                                       y: box.midY - fitted.height / 2,
                                       width: fitted.width, height: fitted.height))
        }
    }

    /// The table whose `</>` button is under a mouse event, if any.
    func tableRawButtonHit(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        // A pointer-sized target: the drawn glyph is small chrome, and the
        // margin around it is empty, so the click box can be generous for free.
        return visibleTableRawButtons()
            .first { $0.rect.insetBy(dx: -4, dy: -4).contains(point) }?.blockIndex
    }

    /// Puts the caret at the start of a table, which is what renders it raw.
    /// Nothing here teaches the renderer about the button: this is the same
    /// state a click into the table already produces.
    func activateRawTableEditing(blockIndex: Int) {
        guard blockIndex < blocks.count else { return }
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        // Suppressed for the same reason `mouseDown` suppresses it: re-centring
        // the viewport because the user clicked something feels glitchy.
        suppressTypewriterCentering = true
        setSelectedRange(NSRange(location: blocks[blockIndex].range.location, length: 0))
        suppressTypewriterCentering = false
    }
}
