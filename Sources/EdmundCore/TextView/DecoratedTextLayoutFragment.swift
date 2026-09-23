import AppKit

/// Layout fragment that draws its paragraph's `BlockDecoration` behind the
/// text and any `FragmentOverlay` images at their characters' positions.
final class DecoratedTextLayoutFragment: NSTextLayoutFragment {

    /// Decorations drawn behind the paragraph, outermost first.
    let decorations: [BlockDecoration]
    /// Paragraph-relative anchor offsets and their overlays.
    let overlays: [(offset: Int, overlay: FragmentOverlay)]
    /// Whether the text is antialiased (editor-wide setting).
    let antialias: Bool
    /// Each overflowing cell's x and pre-laid-out lines, from a detached
    /// scratch text stack sized to the column's content width. The stack
    /// itself is retained (`scratchStacks`) so the line fragments stay valid.
    private let resolvedCellWraps: [(wrap: TableCellWrap, lines: [NSTextLineFragment])]
    private let scratchStacks: [(NSTextContentStorage, NSTextLayoutManager, NSTextContainer)]

    /// A fenced code block's display language, present only on the block's
    /// opening fence line ("" for a fence naming no language). Non-nil marks
    /// this as a code box's top fragment — drives the top-padding shave.
    let codeBlockLabel: String?
    /// The non-empty display language on the block's second row — the
    /// fragment that paints the label, reaching up over the fence row
    /// (see `.codeBlockLabelAnchor`).
    let codeBlockLabelAnchor: String?
    /// The label's font — a smaller cut of the editor's monospace font,
    /// handed over at vend time (the fragment has no theme access).
    let codeBlockLabelFont: NSFont

    /// Whitespace-mark config, or nil when invisibles are off. Drawn over the
    /// real glyphs after `super.draw` — see EditorTextView+Invisibles.
    let invisibles: InvisiblesConfig?

    /// Indent-guide columns for a nested list item, container-relative; empty
    /// when the item is top-level or the setting is off. Drawn under the text.
    let listGuides: [CGFloat]

    /// The editor that vended this fragment, for the settings its draw reads
    /// *live* rather than capturing (`focusMode`). Weak — the layout manager
    /// outlives no editor, but a fragment must never keep one alive.
    /// See EditorTextView+FocusMode.
    weak var owner: EditorTextView?

    init(textElement: NSTextElement, range: NSTextRange?,
         decorations: [BlockDecoration],
         overlays: [(offset: Int, overlay: FragmentOverlay)],
         cellWraps: [TableCellWrap],
         antialias: Bool,
         codeBlockLabel: String? = nil,
         codeBlockLabelAnchor: String? = nil,
         codeBlockLabelFont: NSFont = .monospacedSystemFont(ofSize: 10, weight: .regular),
         invisibles: InvisiblesConfig? = nil,
         listGuides: [CGFloat] = [],
         owner: EditorTextView? = nil) {
        self.listGuides = listGuides
        self.owner = owner
        self.decorations = decorations
        self.overlays = overlays
        self.antialias = antialias
        self.codeBlockLabel = codeBlockLabel
        self.codeBlockLabelAnchor = codeBlockLabelAnchor
        self.codeBlockLabelFont = codeBlockLabelFont
        self.invisibles = invisibles
        var resolved: [(wrap: TableCellWrap, lines: [NSTextLineFragment])] = []
        var stacks: [(NSTextContentStorage, NSTextLayoutManager, NSTextContainer)] = []
        for wrap in cellWraps {
            let contentStorage = NSTextContentStorage()
            contentStorage.textStorage = NSTextStorage(attributedString: wrap.styled)
            let layoutManager = NSTextLayoutManager()
            contentStorage.addTextLayoutManager(layoutManager)
            let container = NSTextContainer(
                size: NSSize(width: max(1, wrap.contentWidth), height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            layoutManager.textContainer = container
            var lines: [NSTextLineFragment] = []
            layoutManager.enumerateTextLayoutFragments(
                from: layoutManager.documentRange.location, options: [.ensuresLayout]
            ) { frag in
                lines.append(contentsOf: frag.textLineFragments)
                return true
            }
            resolved.append((wrap, lines))
            stacks.append((contentStorage, layoutManager, container))
        }
        self.resolvedCellWraps = resolved
        self.scratchStacks = stacks
        super.init(textElement: textElement, range: range)
    }

    /// Where a wrapped cell's first line starts, relative to the fragment's
    /// top: the row's own line box does not start at the fragment's edge (the
    /// row paragraph reserves `paragraphSpacingBefore` above it), and a wrapped
    /// cell has to sit on that same line, not above it.
    private var cellWrapTopInset: CGFloat {
        textLineFragments.first?.typographicBounds.minY ?? 0
    }

    /// The paragraph-relative character index under `point` (fragment
    /// coordinates) when it lands on a wrapped cell's drawn text, else nil.
    ///
    /// The cell's real characters are hidden at ~zero advance and one of them
    /// carries the column's whole kern pad, so the layout manager's own
    /// hit-testing maps every point in the cell to that single character. The
    /// scratch layout holds the very characters the document has (styling never
    /// changes characters — storage == rawSource), so resolving the point
    /// against it instead is exact.
    func cellWrapCharacterIndex(for point: CGPoint) -> Int? {
        for (wrap, lines) in resolvedCellWraps {
            guard point.x >= wrap.x, point.x <= wrap.x + wrap.contentWidth,
                  !lines.isEmpty else { continue }
            var top = cellWrapTopInset
            for (li, line) in lines.enumerated() {
                let height = line.typographicBounds.height
                // Past the last line means the click was in the row's bottom
                // padding — that still belongs to the last line.
                let belowLastLine = point.y >= top + height
                guard !belowLastLine || li == lines.count - 1 else {
                    top += height
                    continue
                }
                // A click below the last line goes to the end of the cell's
                // text, not to whatever character happens to sit above the
                // point — the same place an unwrapped cell's blank space sends
                // it. Only a click *on* a line's own vertical band resolves by x.
                if belowLastLine {
                    return wrap.charStart + line.characterRange.upperBound
                }
                let dx = cellWrapLineOffset(line, contentWidth: wrap.contentWidth, align: wrap.align)
                // The line's own bounds carry the scratch container's stacking
                // offset; only its x matters here, so probe at its own midY.
                let local = CGPoint(x: point.x - wrap.x - dx, y: line.typographicBounds.midY)
                var index = line.characterIndex(for: local)
                guard index >= 0 else { return nil }
                // `characterIndex(for:)` names the character *under* the point,
                // which is not where a click puts a caret: AppKit's insertion
                // rule rounds at the glyph's midpoint, so a click on the right
                // half of a letter lands after it. Without this every such
                // click came out one character early.
                let lineEnd = line.characterRange.upperBound
                if index < lineEnd {
                    let left = line.locationForCharacter(at: index).x
                    let right = index + 1 <= lineEnd
                        ? line.locationForCharacter(at: index + 1).x : left
                    if right > left, local.x > (left + right) / 2 { index += 1 }
                }
                return wrap.charStart + index
            }
        }
        return nil
    }

    /// The inverse of `cellWrapCharacterIndex`: fragment-local rects covering
    /// the part of `range` (paragraph-relative) that falls inside a wrapped
    /// cell's drawn text, one rect per visual line it spans. A zero-length
    /// range yields the caret's single zero-width rect. Empty when the range
    /// touches no wrapped cell, which is every row whose cells all fit.
    ///
    /// Both line-fragment index APIs count in the scratch string's own
    /// coordinates, not the line's (verified: `characterIndex(for:)` at the
    /// left edge of the second line returns that line's first index, not 0),
    /// so `charStart` is the only shift needed either way.
    func cellWrapRects(forParagraphRange range: NSRange) -> [CGRect] {
        for (wrap, lines) in resolvedCellWraps where !lines.isEmpty {
            let cell = NSRange(location: wrap.charStart, length: wrap.styled.length)
            // A caret sitting on either edge belongs to the cell; a selection
            // has to actually overlap it.
            let local: NSRange
            if range.length == 0 {
                guard range.location >= cell.location,
                      range.location <= cell.upperBound else { continue }
                local = NSRange(location: range.location - wrap.charStart, length: 0)
            } else {
                let hit = NSIntersectionRange(range, cell)
                guard hit.length > 0 else { continue }
                local = NSRange(location: hit.location - wrap.charStart, length: hit.length)
            }

            var rects: [CGRect] = []
            var top = cellWrapTopInset
            for line in lines {
                let height = line.typographicBounds.height
                let lineRange = line.characterRange
                let dx = cellWrapLineOffset(line, contentWidth: wrap.contentWidth,
                                            align: wrap.align)
                defer { top += height }
                if local.length == 0 {
                    // The caret goes on the first line that can hold it, which
                    // at a soft break is the line it broke *from* — the same
                    // line a click at that point would have resolved to.
                    guard local.location < lineRange.upperBound
                            || line === lines.last else { continue }
                    let x = line.locationForCharacter(
                        at: min(local.location, lineRange.upperBound)).x
                    return [CGRect(x: wrap.x + dx + x, y: top, width: 0, height: height)]
                }
                let hit = NSIntersectionRange(local, lineRange)
                guard hit.length > 0 else { continue }
                let from = line.locationForCharacter(at: hit.location).x
                let to = line.locationForCharacter(at: hit.upperBound).x
                rects.append(CGRect(x: wrap.x + dx + from, y: top,
                                    width: to - from, height: height))
            }
            if !rects.isEmpty { return rects }
        }
        return []
    }

    /// The paragraph offset one visual line up (`-1`) or down (`+1`) from
    /// `offset`, inside the wrapped cell holding it. Nil when the offset is not
    /// in a wrapped cell or the move would leave it — the caller then hands the
    /// key back to ordinary vertical movement, which walks to the row above or
    /// below.
    func cellWrapOffset(fromParagraphOffset offset: Int, lineDelta: Int) -> Int? {
        for (wrap, lines) in resolvedCellWraps where !lines.isEmpty {
            let cell = NSRange(location: wrap.charStart, length: wrap.styled.length)
            guard offset >= cell.location, offset <= cell.upperBound else { continue }
            let local = offset - wrap.charStart
            guard let index = lines.firstIndex(where: {
                local < $0.characterRange.upperBound
            }) ?? (lines.indices.last) else { return nil }
            let target = index + lineDelta
            guard lines.indices.contains(target) else { return nil }
            let here = lines[index], there = lines[target]
            // Alignment shifts each line independently, so the x has to be
            // taken back out of the source line's shift and into the target's.
            let dxHere = cellWrapLineOffset(here, contentWidth: wrap.contentWidth,
                                            align: wrap.align)
            let dxThere = cellWrapLineOffset(there, contentWidth: wrap.contentWidth,
                                             align: wrap.align)
            let x = here.locationForCharacter(
                at: min(local, here.characterRange.upperBound)).x
            let hit = there.characterIndex(
                for: CGPoint(x: x + dxHere - dxThere, y: there.typographicBounds.midY))
            guard hit >= 0 else { return nil }
            return wrap.charStart + hit
        }
        return nil
    }

    /// Extra row height needed to fit the tallest wrapped cell, beyond the
    /// row's natural (single-line) height.
    private var tableRowExtraHeight: CGFloat {
        guard !resolvedCellWraps.isEmpty else { return 0 }
        let tallest = resolvedCellWraps
            .map { $0.lines.reduce(0) { $0 + $1.typographicBounds.height } }
            .max() ?? 0
        // Measured against the row's own *line* height, not the whole fragment:
        // the fragment also carries the row's vertical padding, and a row whose
        // cells all overflow has no visible characters left to give its line any
        // height at all. Comparing against the fragment then hides the whole
        // shortfall behind the padding, and the row collapses onto it — which is
        // what a header of long labels did, while the data rows beside it grew.
        let lineHeight = textLineFragments.reduce(0) { $0 + $1.typographicBounds.height }
        return max(0, tallest - lineHeight)
    }

    required init?(coder: NSCoder) {
        fatalError("DecoratedTextLayoutFragment does not support coding")
    }

    /// Fragment-local x of the text container's left edge. The fragment's
    /// frame hugs the laid-out text, so container x = 0 sits at -frame.minX.
    private var containerLeft: CGFloat { -layoutFragmentFrame.minX }

    private var containerWidth: CGFloat {
        textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
    }

    /// A box decoration's `bottomPad` grows the fragment's own frame (not just
    /// its drawing): TextKit 2 leaves trailing `paragraphSpacing` out of the
    /// fragment, so padding added that way is dead space — clicks there miss the
    /// text. Making the fragment frame taller means the line fragments stay
    /// anchored at the top, the extra height is genuine clickable space below
    /// the last line, the next block tiles clear of it, and the box (drawn over
    /// the full frame height) covers it. Mirrors how the header's raised
    /// minimumLineHeight makes the top padding clickable text space.
    ///
    /// Padding is *summed* across stacked boxes: when a nested callout is the
    /// last line of its parent, the line needs the nested box's bottom padding
    /// *and* the parent's below it (see `draw`), so both fit.
    private var boxBottomPad: CGFloat {
        decorations.reduce(0) { acc, deco in
            if case .box(_, _, _, _, let bottomPad) = deco.kind { return acc + bottomPad }
            return acc
        }
    }

    /// Height to actually paint a filled decoration (box / left bar) over,
    /// which is *not* always the full frame height. When a callout or quote is
    /// the last block AND the document ends with a newline, TextKit 2 folds the
    /// document's final empty line into this (the preceding) layout fragment
    /// instead of giving it its own fragment — it shows up as a trailing
    /// zero-length line fragment. Painting the decoration over the full frame
    /// then floods the callout color onto that trailing empty line (the
    /// "extra colored line at the bottom" bug). Detect the absorbed empty line
    /// and stop the fill at the last real content line plus the box's bottom
    /// padding.
    var decorationDrawHeight: CGFloat {
        let full = layoutFragmentFrame.height
        let lines = textLineFragments
        guard lines.count > 1, let last = lines.last,
              last.characterRange.length == 0 else { return full }
        // Bottom of the last line that actually holds text (fragment-local).
        let contentBottom = lines.dropLast().map { $0.typographicBounds.maxY }.max() ?? 0
        // `super` frame excludes our bottomPad; its extent past the content is
        // exactly the absorbed empty line. Remove that, keep the bottomPad.
        let emptyLineHeight = max(0, super.layoutFragmentFrame.height - contentBottom)
        return max(0, full - emptyLineHeight)
    }

    override var layoutFragmentFrame: CGRect {
        var frame = super.layoutFragmentFrame
        // A row is never both a box and a table row, so at most one of these
        // two is ever nonzero.
        frame.size.height += boxBottomPad + tableRowExtraHeight
        return frame
    }

    override var renderingSurfaceBounds: CGRect {
        var bounds = super.renderingSurfaceBounds
        let frame = layoutFragmentFrame
        if !decorations.isEmpty {
            bounds = bounds.union(CGRect(x: containerLeft - 4, y: 0,
                                         width: containerWidth + 8, height: frame.height))
        }
        // Guides sit left of the item's text, outside the text-hugging frame.
        if !listGuides.isEmpty {
            bounds = bounds.union(CGRect(x: containerLeft, y: 0,
                                         width: containerWidth, height: frame.height))
        }
        for (offset, overlay) in overlays {
            if let rect = overlayRect(anchorOffset: offset, overlay: overlay) {
                bounds = bounds.union(rect.insetBy(dx: -2, dy: -2))
            }
        }
        // The language label sits at the container's right edge, far outside
        // this (short, invisible) fence line's own text frame.
        if let rect = codeBlockLabelRect() {
            bounds = bounds.union(rect.insetBy(dx: -2, dy: -2))
        }
        // The line-ending mark (¬) sits just past the last glyph — give it room.
        if invisibles != nil {
            let frame = layoutFragmentFrame
            bounds = bounds.union(CGRect(x: containerLeft, y: 0,
                                         width: containerWidth + 12, height: frame.height))
        }
        return bounds
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        // Focus mode fades this whole fragment — text, boxes, bars, overlays —
        // as one group. See EditorTextView+FocusMode.
        let dimming = beginFocusDim(in: context)
        defer { endFocusDim(dimming, in: context) }
        context.saveGState()
        drawListGuides(at: point, in: context)
        // Decorations are stacked outermost-first. Each box stops short of the
        // fragment bottom by the padding of the boxes drawn before it, so an
        // outer box's bottom padding stays visible *below* an inner nested box
        // (e.g. the parent callout's padding under a nested callout) instead of
        // being covered by it.
        var precedingBottomPad: CGFloat = 0
        for (index, decoration) in decorations.enumerated() {
            let topInset = index == decorations.count - 1 ? codeBoxTopShave : 0
            drawDecoration(decoration, at: point, in: context,
                           bottomInset: precedingBottomPad, topInset: topInset)
            if case .box(_, _, _, _, let bottomPad) = decoration.kind {
                precedingBottomPad += bottomPad
            }
        }
        context.restoreGState()
        context.saveGState()
        context.setShouldAntialias(antialias)
        super.draw(at: point, in: context)
        context.restoreGState()
        for (offset, overlay) in overlays {
            guard let rect = overlayRect(anchorOffset: offset, overlay: overlay) else { continue }
            let drawRect = rect.offsetBy(dx: point.x, dy: point.y)
            if let image = overlay.image {
                // Draw the (resolution-independent) NSImage into the flipped context,
                // so it rasterizes at the screen's backing scale — crisp on Retina,
                // and positioned precisely. (Converting to a CGImage first would bake
                // it at 1×, then upscale: soft, and quantized a pixel low.) The math
                // image carries a small transparent inset, so the flipped draw can't
                // clip a descender at the image edge.
                let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = nsContext
                image.draw(in: deviceAligned(drawRect, in: context), from: .zero,
                           operation: .sourceOver,
                           fraction: 1, respectFlipped: true, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
            } else if let path = overlay.path, let color = overlay.pathColor {
                // Stroke the vector path directly in CG — never rasterize it to
                // an image first: an image drawn on a multi-line fragment wedges
                // its layout to one line (see the FragmentOverlay note). Path
                // coords are bounds-local and y-down, matching this flipped
                // context, so a translate places them.
                context.saveGState()
                context.translateBy(x: drawRect.minX, y: drawRect.minY)
                context.addPath(path)
                context.setStrokeColor(color.cgColor)
                context.setLineWidth(overlay.pathLineWidth)
                context.setLineCap(.round)
                context.setLineJoin(.round)
                context.strokePath()
                context.restoreGState()
            }
        }
        // Overflowing table cells: the real characters are hidden, so draw
        // each cell's pre-wrapped lines here instead, stacked top-down at the
        // cell's column x, each line shifted for the column's alignment.
        for (wrap, lines) in resolvedCellWraps {
            var y = point.y + cellWrapTopInset
            for line in lines {
                let dx = cellWrapLineOffset(line, contentWidth: wrap.contentWidth, align: wrap.align)
                line.draw(at: CGPoint(x: point.x + wrap.x + dx, y: y), in: context)
                y += line.typographicBounds.height
            }
        }
        drawCodeBlockLabel(at: point, in: context)
        drawInvisibles(at: point, in: context)
    }

    /// The excess of this row's glyph cap-top gap (baseline minus capHeight)
    /// over its descender-bottom remainder — the ink asymmetry within one
    /// monospace row. All the block's rows (fences included) share the mono
    /// font, so any row's own first line yields the block-wide value.
    private var codeRowInkGapExcess: CGFloat {
        guard let line = textLineFragments.first,
              line.characterRange.length > 0,
              let font = line.attributedString.attribute(
                  .font, at: line.characterRange.location, effectiveRange: nil) as? NSFont
        else { return 0 }
        let capTopGap = line.glyphOrigin.y - font.capHeight
        // font.descender is negative; glyph ink ends at baseline - descender.
        let bottomGap = line.typographicBounds.height - (line.glyphOrigin.y - font.descender)
        return max(0, capTopGap - bottomGap)
    }

    /// How far below this fragment's top the code box's top edge sits — only
    /// nonzero on a code block's opening fence line (the box's top fragment).
    /// Evens out the box's visible top vs bottom padding, which is otherwise
    /// top-heavy by two asymmetries the closing fence row doesn't mirror:
    /// the lineSpacing TextKit stacks *above* each row's glyphs
    /// (typographicBounds.minY), and the glyph ink gap
    /// (`codeRowInkGapExcess`). Both are shaved so the ink-to-box distances
    /// match.
    private var codeBoxTopShave: CGFloat {
        guard codeBlockLabel != nil, let line = textLineFragments.first else { return 0 }
        return max(0, line.typographicBounds.minY) + codeRowInkGapExcess
    }

    /// Fragment-local rect (y-down, origin at this fragment's top-left) for
    /// the language label: pinned to the code box's top-right corner with the
    /// same 10pt gap on top as on the right — mirroring Read mode's
    /// absolutely-positioned label. Computed on the block's *second* row
    /// (negative y, reaching up over the fence row; see
    /// `.codeBlockLabelAnchor` for why the fence fragment can't draw it).
    /// Nil when this fragment isn't the label row.
    func codeBlockLabelRect() -> CGRect? {
        guard let label = codeBlockLabelAnchor, !label.isEmpty,
              let line = textLineFragments.first else { return nil }
        let size = (label as NSString).size(withAttributes: [.font: codeBlockLabelFont])
        let inset: CGFloat = 10
        // Box top, in this fragment's coords: one fence row above, i.e. the
        // fence row's glyph-row height less the shave's ink-gap part. The
        // fence row shares this row's mono metrics, so its own line stands in.
        let boxTop = -(line.typographicBounds.height - codeRowInkGapExcess)
        // Align the label's ink top (not its line-box top) to the 10pt gap.
        let inkTopBearing = max(0, codeBlockLabelFont.ascender - codeBlockLabelFont.capHeight)
        return CGRect(x: containerLeft + containerWidth - ceil(size.width) - inset,
                      y: boxTop + inset - inkTopBearing,
                      width: ceil(size.width), height: ceil(size.height))
    }

    /// Paints the language label at `codeBlockLabelRect()` — direct
    /// `NSAttributedString` drawing, not an `NSImage`, so this stays outside
    /// the proven image-wedge mechanism (an image on a wrapping fragment
    /// wedges its layout to one line; see FragmentOverlay).
    private func drawCodeBlockLabel(at point: CGPoint, in context: CGContext) {
        guard let label = codeBlockLabelAnchor, let rect = codeBlockLabelRect() else { return }
        let drawRect = rect.offsetBy(dx: point.x, dy: point.y)
        let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        NSAttributedString(string: label, attributes: [
            .font: codeBlockLabelFont, .foregroundColor: NSColor.secondaryLabelColor,
        ]).draw(at: drawRect.origin)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// `rect` with its origin moved to the nearest whole device pixel, leaving
    /// its size alone. An overlay is anchored to a text baseline (and display
    /// math to a centered x), so its origin is essentially never pixel-aligned —
    /// and a bitmap blitted to a fractional device offset gets resampled, which
    /// spread the same ink over ~39% more device pixels and made equations look
    /// bolder in Edit mode than in Read mode. Rounding happens in *device* space,
    /// not user space, because a scrolled clip view can leave the CTM's own
    /// translation on a fraction of a point.
    private func deviceAligned(_ rect: CGRect, in context: CGContext) -> CGRect {
        var device = context.convertToDeviceSpace(rect.origin)
        device.x.round()
        device.y.round()
        return CGRect(origin: context.convertToUserSpace(device), size: rect.size)
    }

    /// Fragment-local rect for an overlay image, anchored to the character at
    /// the given paragraph-relative offset.
    private func overlayRect(anchorOffset: Int, overlay: FragmentOverlay) -> CGRect? {
        guard let line = textLineFragments.first(where: {
            NSLocationInRange(anchorOffset, $0.characterRange)
        }) ?? textLineFragments.last else { return nil }
        let anchorX = line.typographicBounds.minX
            + line.locationForCharacter(at: anchorOffset).x
        // Baseline (flipped coords): the line's glyph origin sits at its
        // typographic origin plus the ascent-derived glyph origin.
        let baselineY = line.typographicBounds.minY + line.glyphOrigin.y
        return CGRect(x: anchorX + overlay.bounds.minX,
                      y: baselineY - overlay.bounds.height - overlay.bounds.minY,
                      width: overlay.bounds.width,
                      height: overlay.bounds.height)
    }

    /// Fragment-local y of the first line's glyph top (baseline minus the
    /// line's font ascender). The line box can hold extra space above the
    /// glyphs (lineSpacing lands there), which a text-hugging bar skips.
    private var firstLineGlyphTop: CGFloat? {
        guard let line = textLineFragments.first,
              line.characterRange.length > 0,
              let font = line.attributedString.attribute(
                  .font, at: line.characterRange.location, effectiveRange: nil) as? NSFont
        else { return nil }
        return line.typographicBounds.minY + line.glyphOrigin.y - font.ascender
    }

    /// The gray for editor chrome drawn as thin lines (table borders, list
    /// indent guides). In dark mode `separatorColor` is ~10% ink and all but
    /// vanishes, so use the shared marker gray there; light mode keeps
    /// `separatorColor`. Read mode's `--table-border` matches.
    private var chromeLineColor: NSColor {
        NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? EditorTextView.darkRuleGray : NSColor.separatorColor
    }

    /// Vertical hairlines marking a list item's indent columns, drawn under the
    /// text. Offsets are container-relative, so they land on the same columns as
    /// the markers no matter how this item's own first line is indented (an
    /// ordered or active marker shifts `point.x`, which is the *text* start —
    /// hence `containerLeft` rather than `point.x` alone). They are measured
    /// from the container's text origin, which sits `lineFragmentPadding` in
    /// from its left edge — the same origin the paragraph's head indents use.
    ///
    /// All but the last offset are the item's ancestor columns, spanning its
    /// whole height: consecutive list items tile with no gap (list paragraphs
    /// carry no paragraph spacing), so the per-fragment fills read as one
    /// continuous line down a nested run. Height is `decorationDrawHeight`, not
    /// the raw frame, so a list at the end of the document doesn't paint a stub
    /// over the absorbed trailing empty line.
    ///
    /// The last offset is the item's *own* column, drawn only from its second
    /// line down — a wrapped continuation line then stays visibly tied to its
    /// own bullet, while the first line leaves room for the marker itself.
    private func drawListGuides(at point: CGPoint, in context: CGContext) {
        guard !listGuides.isEmpty else { return }
        // Filled at exactly one device pixel rather than stroked, for the same
        // reason as the table's column borders — see `.tableRow`.
        let scale = max(1, abs(context.convertToDeviceSpace(CGSize(width: 1, height: 1)).width))
        let hairline = 1 / scale
        let padding = textLayoutManager?.textContainer?.lineFragmentPadding ?? 0
        let originX = point.x + containerLeft + padding
        let height = decorationDrawHeight
        context.setFillColor(chromeLineColor.cgColor)

        func fill(_ offset: CGFloat, from top: CGFloat) {
            guard height > top else { return }
            let lineX = (((originX + offset) * scale).rounded()) / scale
            context.fill(CGRect(x: lineX, y: point.y + top,
                                width: hairline, height: height - top))
        }

        for offset in listGuides.dropLast() { fill(offset, from: 0) }
        // Second *real* line: a trailing zero-length line is the document's
        // final empty line absorbed into this fragment, not a wrapped line.
        if let wrapped = textLineFragments.filter({ $0.characterRange.length > 0 })
            .dropFirst().first, let own = listGuides.last {
            fill(own, from: wrapped.typographicBounds.minY)
        }
    }

    private func drawDecoration(_ decoration: BlockDecoration, at point: CGPoint,
                                in context: CGContext, bottomInset: CGFloat = 0,
                                topInset: CGFloat = 0) {
        let frame = layoutFragmentFrame
        // Filled decorations (box, bar) stop above an absorbed trailing empty
        // line; center-line decorations (rule, table) still use the full frame.
        let fillHeight = decorationDrawHeight
        // Fragment-local rect spanning the full text column for this fragment.
        let columnRect = CGRect(x: point.x + containerLeft, y: point.y,
                                width: containerWidth, height: fillHeight)

        switch decoration.kind {
        case .box(let background, let borderColor, let edges, let borderWidth, _):
            // The fragment frame already includes any box bottomPad (see
            // layoutFragmentFrame), so columnRect covers the padded area. A
            // nested box insets symmetrically so it sits within its parent box,
            // and stops `bottomInset` short of the frame bottom so the enclosing
            // box's padding shows below it.
            var columnRect = decoration.inset > 0
                ? columnRect.insetBy(dx: decoration.inset, dy: 0)
                : columnRect
            columnRect.size.height -= bottomInset + topInset
            columnRect.origin.y += topInset
            context.setFillColor(background.cgColor)
            context.fill(columnRect)
            if let borderColor, !edges.isEmpty {
                context.setFillColor(borderColor.cgColor)
                if edges.contains(.left) {
                    context.fill(CGRect(x: columnRect.minX, y: columnRect.minY,
                                        width: borderWidth, height: columnRect.height))
                }
                if edges.contains(.right) {
                    context.fill(CGRect(x: columnRect.maxX - borderWidth, y: columnRect.minY,
                                        width: borderWidth, height: columnRect.height))
                }
                if edges.contains(.top) {
                    context.fill(CGRect(x: columnRect.minX, y: columnRect.minY,
                                        width: columnRect.width, height: borderWidth))
                }
                if edges.contains(.bottom) {
                    context.fill(CGRect(x: columnRect.minX, y: columnRect.maxY - borderWidth,
                                        width: columnRect.width, height: borderWidth))
                }
            }

        case .leftBar(let color, let width):
            // The bar sits immediately left of the text (the paragraph style
            // insets the text by the bar's width) — or `inset` further right,
            // for a nested quote's bar next to its own level's text.
            var barTop = point.y
            var barHeight = fillHeight
            if decoration.hugsTextTop, let glyphTop = firstLineGlyphTop {
                barTop += glyphTop
                barHeight -= glyphTop
            }
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: point.x - width + decoration.inset, y: barTop,
                                width: width, height: barHeight))

        case .tableRow(let xOffsets, let width, let leftInset, let separator,
                       let bottomBorder, let topInset):
            // Offsets are text-relative; the fragment's origin is the text start.
            let borderColor = chromeLineColor
            // Column borders are FILLED at exactly one device pixel rather than
            // stroked: a 1pt stroke straddling a pixel boundary lands on two
            // device rows on a Retina display, which made the verticals read
            // twice as heavy as the row rules beside them.
            // `ctm.a` reports the user-space transform only (1 even on Retina);
            // converting a unit size into device space gives the real backing scale.
            let scale = max(1, abs(context.convertToDeviceSpace(CGSize(width: 1, height: 1)).width))
            let hairline = 1 / scale
            context.setFillColor(borderColor.cgColor)
            // The table is closed on all four sides, like Notes': the two outer
            // verticals join the column borders, and the header carries the top
            // rule the way the last row carries the bottom one. A closed grid is
            // also what lets a cell-selection box stand on a real line wherever
            // it is drawn, rather than floating at an open edge.
            for x in [0] + xOffsets + [width - leftInset] {
                let lineX = (((point.x + x - (x == 0 ? leftInset : 0)) * scale).rounded()) / scale
                context.fill(CGRect(x: lineX, y: point.y + topInset,
                                    width: hairline, height: frame.height - topInset))
            }
            // Filled at one device pixel, exactly like the column borders above
            // — a 1pt stroke is two device rows on a Retina display, which is
            // what made the row rules read twice the weight of the verticals
            // they meet. The whole grid is one hairline now.
            func rule(atY y: CGFloat) {
                let lineY = ((y * scale).rounded()) / scale
                context.fill(CGRect(x: point.x - leftInset, y: lineY,
                                    width: width, height: hairline))
            }
            // `topInset` is reserved only by the header row, so it also says
            // which row owns the table's top edge.
            if topInset > 0 { rule(atY: point.y + topInset) }
            if separator { rule(atY: point.y + frame.height / 2) }
            // Inside the drawing row, not below it: the row beneath repaints on
            // its own (a caret move restyles one row and dirties only its
            // rect), and it would erase a line it knows nothing about — the row
            // that owns the line never being asked to draw it again.
            if bottomBorder { rule(atY: point.y + frame.height - hairline) }

        case .horizontalRule(let color, let centerOffset):
            // Filled at a fixed 3 device pixels (1.5pt on Retina) rather than
            // stroked at 1pt: a section divider wants a little more presence
            // than a table gridline, and filling keeps the edges crisp.
            let scale = max(1, abs(context.convertToDeviceSpace(CGSize(width: 1, height: 1)).width))
            let thickness = 3 / scale
            let y = ((point.y + frame.height / 2 + centerOffset) * scale).rounded() / scale
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: columnRect.minX, y: y,
                                width: columnRect.maxX - columnRect.minX, height: thickness))
        }
    }
}
