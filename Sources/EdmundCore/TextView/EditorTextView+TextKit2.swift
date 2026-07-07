import AppKit

// MARK: - TextKit 2 Support
//
// The editor runs on TextKit 2 (NSTextLayoutManager): layout is viewport-based
// — the system only lays out what's on screen, which is what makes large
// documents tractable. The hard rule that follows: never touch
// `NSTextView.layoutManager` or store NSTextBlock/NSTextTable attributes —
// either silently switches the view back to TextKit 1 for good.
//
// Two custom attributes drive a custom layout fragment:
//
// - `.blockDecoration` (paragraph-level): callout boxes, quote bars, table
//   borders, thematic-break rules. Fragment frames tile vertically, so
//   per-paragraph drawing renders a multi-line quote run as one continuous
//   box/bar.
// - `.fragmentOverlay` (character-level): images drawn at a character's
//   position — callout header (icon + title), rendered math, list bullets and
//   checkboxes. TextKit 1 rendered `.attachment` over any character; TextKit 2
//   only honors attachments on U+FFFC, which the storage==rawSource invariant
//   forbids. Instead the anchor character is hidden, `.kern` reserves the
//   image's advance width (the same trick the table renderer uses for column
//   alignment), and the fragment draws the image at the anchor's position.

public extension NSAttributedString.Key {
    /// Paragraph-level decoration drawn behind the text by
    /// `DecoratedTextLayoutFragment`. Value: `BlockDecoration`.
    static let blockDecoration = NSAttributedString.Key("MarkdownEditor.blockDecoration")
    /// Character-level image drawn at the character's position by
    /// `DecoratedTextLayoutFragment`. Value: `FragmentOverlay`. The styling
    /// code pairs it with a hidden anchor glyph plus `.kern` for layout space.
    static let fragmentOverlay = NSAttributedString.Key("MarkdownEditor.fragmentOverlay")
}

/// Value object describing what to draw behind a decorated paragraph.
/// Reference type (NSObject) so it lives in attributed strings; value
/// equality so attribute-run merging and the test oracle behave.
public final class BlockDecoration: NSObject, @unchecked Sendable {

    public enum Kind: Equatable {
        /// Filled box across the text column (callouts), with optional borders.
        /// `bottomPad` extends the fill/border below the fragment's text frame —
        /// TextKit 2 does not include trailing `paragraphSpacing` in the
        /// fragment height, so a callout's last line carries the bottom padding
        /// here (and a matching paragraphSpacing pushes the next block clear).
        case box(background: NSColor, borderColor: NSColor?,
                 borderEdges: CalloutStyle.Edges, borderWidth: CGFloat,
                 bottomPad: CGFloat)
        /// Vertical bar just left of the paragraph's text (plain block quotes).
        case leftBar(color: NSColor, width: CGFloat)
        /// Table-row chrome: vertical column borders at text-relative x
        /// offsets, and a horizontal rule through the separator row. `width`
        /// is the table's full width; `leftInset` the text's inset from the
        /// table's left edge.
        case tableRow(columnXOffsets: [CGFloat], width: CGFloat,
                      leftInset: CGFloat, separator: Bool)
        /// Horizontal hairline across the text column, drawn `centerOffset`
        /// points below the fragment's vertical center. The offset compensates
        /// for adjacent text sitting at its baseline (low in its line box), so
        /// the rule looks equidistant from the text above and below rather
        /// than hugging the line above it.
        case horizontalRule(color: NSColor, centerOffset: CGFloat)
    }

    public let kind: Kind
    /// Horizontal inset (points) from the text column's left and right edges at
    /// which a `.box` is drawn. Non-zero for boxes nested inside another box
    /// (e.g. a callout inside a callout), so the inner box sits within the outer
    /// one. Ignored by `.leftBar` (which draws relative to the indented text
    /// origin and so already follows nesting) and the other kinds.
    public let inset: CGFloat

    public init(_ kind: Kind, inset: CGFloat = 0) {
        self.kind = kind
        self.inset = inset
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? BlockDecoration else { return false }
        return kind == other.kind && inset == other.inset
    }

    public override var hash: Int {
        switch kind {
        case .box: return 1
        case .leftBar: return 2
        case .tableRow: return 3
        case .horizontalRule: return 4
        }
    }
}

/// An ordered stack of decorations drawn behind one paragraph, outermost
/// first. Used when nesting puts more than one box/bar on the same line — e.g.
/// a callout's outer box plus an inner nested callout's box. A single
/// decoration still uses a bare `BlockDecoration`; the fragment reads either.
public final class BlockDecorationList: NSObject, @unchecked Sendable {
    public let decorations: [BlockDecoration]

    public init(_ decorations: [BlockDecoration]) {
        self.decorations = decorations
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? BlockDecorationList else { return false }
        return decorations == other.decorations
    }

    public override var hash: Int { decorations.count }
}

/// An image or stroked vector path drawn at a character's laid-out position,
/// with attachment-style bounds: `bounds.origin.y` is the drawing's bottom
/// relative to the text baseline (negative descends below it).
///
/// The path form exists because of a TextKit 2 wedge: drawing an *image* on a
/// wrapping, multi-line layout fragment collapses that fragment's layout to a
/// single line, while drawing a *shape* does not (see
/// docs/callout-title-wrap-investigation.md). Overlays that can share a line
/// with wrapping text (the custom-callout-title icon) must use the path form.
public final class FragmentOverlay: NSObject, @unchecked Sendable {
    public let image: NSImage?
    /// Stroked path in bounds-local coordinates (y-down, origin at the
    /// bounds' top-left), pre-scaled to the bounds size.
    public let path: CGPath?
    public let pathColor: NSColor?
    public let pathLineWidth: CGFloat
    public let bounds: CGRect

    public init(image: NSImage, bounds: CGRect) {
        self.image = image
        self.path = nil
        self.pathColor = nil
        self.pathLineWidth = 0
        self.bounds = bounds
        super.init()
    }

    public init(path: CGPath, color: NSColor, lineWidth: CGFloat, bounds: CGRect) {
        self.image = nil
        self.path = path
        self.pathColor = color
        self.pathLineWidth = lineWidth
        self.bounds = bounds
        super.init()
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? FragmentOverlay else { return false }
        return other.image === image && other.path == path
            && other.pathColor == pathColor && other.pathLineWidth == pathLineWidth
            && other.bounds == bounds
    }

    public override var hash: Int { Int(bounds.width) ^ Int(bounds.height) }
}

/// Layout fragment that draws its paragraph's `BlockDecoration` behind the
/// text and any `FragmentOverlay` images at their characters' positions.
final class DecoratedTextLayoutFragment: NSTextLayoutFragment {

    /// Decorations drawn behind the paragraph, outermost first.
    let decorations: [BlockDecoration]
    /// Paragraph-relative anchor offsets and their overlays.
    let overlays: [(offset: Int, overlay: FragmentOverlay)]
    /// Whether the text is antialiased (editor-wide setting).
    let antialias: Bool

    init(textElement: NSTextElement, range: NSTextRange?,
         decorations: [BlockDecoration],
         overlays: [(offset: Int, overlay: FragmentOverlay)],
         antialias: Bool) {
        self.decorations = decorations
        self.overlays = overlays
        self.antialias = antialias
        super.init(textElement: textElement, range: range)
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

    override var layoutFragmentFrame: CGRect {
        var frame = super.layoutFragmentFrame
        frame.size.height += boxBottomPad
        return frame
    }

    override var renderingSurfaceBounds: CGRect {
        var bounds = super.renderingSurfaceBounds
        let frame = layoutFragmentFrame
        if !decorations.isEmpty {
            bounds = bounds.union(CGRect(x: containerLeft - 4, y: 0,
                                         width: containerWidth + 8, height: frame.height))
        }
        for (offset, overlay) in overlays {
            if let rect = overlayRect(anchorOffset: offset, overlay: overlay) {
                bounds = bounds.union(rect.insetBy(dx: -2, dy: -2))
            }
        }
        return bounds
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        // Decorations are stacked outermost-first. Each box stops short of the
        // fragment bottom by the padding of the boxes drawn before it, so an
        // outer box's bottom padding stays visible *below* an inner nested box
        // (e.g. the parent callout's padding under a nested callout) instead of
        // being covered by it.
        var precedingBottomPad: CGFloat = 0
        for decoration in decorations {
            drawDecoration(decoration, at: point, in: context, bottomInset: precedingBottomPad)
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
                image.draw(in: drawRect, from: .zero, operation: .sourceOver,
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

    private func drawDecoration(_ decoration: BlockDecoration, at point: CGPoint,
                                in context: CGContext, bottomInset: CGFloat = 0) {
        let frame = layoutFragmentFrame
        // Fragment-local rect spanning the full text column for this fragment.
        let columnRect = CGRect(x: point.x + containerLeft, y: point.y,
                                width: containerWidth, height: frame.height)

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
            columnRect.size.height -= bottomInset
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
            // insets the text by the bar's width).
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: point.x - width, y: point.y,
                                width: width, height: frame.height))

        case .tableRow(let xOffsets, let width, let leftInset, let separator):
            // Offsets are text-relative; the fragment's origin is the text start.
            context.setStrokeColor(NSColor.separatorColor.cgColor)
            context.setLineWidth(1)
            for x in xOffsets {
                let lineX = round(point.x + x) + 0.5
                context.move(to: CGPoint(x: lineX, y: point.y))
                context.addLine(to: CGPoint(x: lineX, y: point.y + frame.height))
            }
            if separator {
                let y = round(point.y + frame.height / 2) + 0.5
                context.move(to: CGPoint(x: point.x - leftInset, y: y))
                context.addLine(to: CGPoint(x: point.x - leftInset + width, y: y))
            }
            context.strokePath()

        case .horizontalRule(let color, let centerOffset):
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(1)
            let y = round(point.y + frame.height / 2 + centerOffset) + 0.5
            context.move(to: CGPoint(x: columnRect.minX, y: y))
            context.addLine(to: CGPoint(x: columnRect.maxX, y: y))
            context.strokePath()
        }
    }
}

// MARK: - Fragment Vending

extension EditorTextView: NSTextLayoutManagerDelegate {
    public nonisolated func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        guard let paragraph = textElement as? NSTextParagraph,
              paragraph.attributedString.length > 0 else {
            return NSTextLayoutFragment(textElement: textElement,
                                        range: textElement.elementRange)
        }
        let str = paragraph.attributedString
        let decoValue = str.attribute(.blockDecoration, at: 0, effectiveRange: nil)
        let decorations: [BlockDecoration]
        if let list = decoValue as? BlockDecorationList {
            decorations = list.decorations
        } else if let single = decoValue as? BlockDecoration {
            decorations = [single]
        } else {
            decorations = []
        }
        var overlays: [(offset: Int, overlay: FragmentOverlay)] = []
        str.enumerateAttribute(.fragmentOverlay,
                               in: NSRange(location: 0, length: str.length),
                               options: []) { value, range, _ in
            if let overlay = value as? FragmentOverlay {
                overlays.append((range.location, overlay))
            }
        }
        // A plain fragment suffices only when there's nothing to draw over the
        // text and antialiasing is on (the default); otherwise vend the custom
        // fragment so its draw can disable antialiasing.
        guard !decorations.isEmpty || !overlays.isEmpty || !textAntialias else {
            return NSTextLayoutFragment(textElement: textElement,
                                        range: textElement.elementRange)
        }
        return DecoratedTextLayoutFragment(textElement: textElement,
                                           range: textElement.elementRange,
                                           decorations: decorations,
                                           overlays: overlays,
                                           antialias: textAntialias)
    }
}

// MARK: - Overlay Application

extension EditorTextView {
    /// Renders `overlay` at `anchor` (a single character): hides the anchor
    /// glyph, reserves the image's advance width with kern so following text
    /// flows around it, and stores the overlay for the layout fragment to draw.
    ///
    /// The kern is capped just short of the full line width: a full-width
    /// image/equation (the common case — anything wider than the column gets
    /// scaled to exactly fill it) would otherwise reserve 100% of the line,
    /// leaving zero room for the hidden markdown text that follows the anchor
    /// on the same line. TextKit then force-wraps that hidden run onto a new
    /// line fragment — and since `minimumLineHeight` (reserveLineHeight) is a
    /// paragraph-wide property applying to every line fragment, that phantom
    /// wrapped line also inflates to the overlay's full height, doubling the
    /// reserved space below the image. The slack is comfortably larger than
    /// any realistic hidden-text width (near-zero at `hiddenFont`'s size).
    func applyOverlay(_ overlay: FragmentOverlay, anchor: NSRange,
                      in result: NSMutableAttributedString) {
        guard anchor.upperBound <= result.length else { return }
        let kernSlack: CGFloat = 8
        let kernWidth = min(overlay.bounds.width, max(0, availableContentWidth - kernSlack))
        result.addAttribute(.font, value: hiddenFont, range: anchor)
        result.addAttribute(.foregroundColor, value: NSColor.clear, range: anchor)
        result.addAttribute(.kern, value: kernWidth, range: anchor)
        result.addAttribute(.fragmentOverlay, value: overlay, range: anchor)
    }

    /// Reserves vertical room for an overlay taller than the text line that
    /// carries it. A `FragmentOverlay` only reserves horizontal advance (kern),
    /// so — unlike the old `NSTextAttachment`, which grew its line fragment —
    /// a tall image (e.g. inline math scaled to a heading's size) would
    /// otherwise overlap the line below. Raises the enclosing paragraph's
    /// `minimumLineHeight` to fit, preserving any other paragraph attributes.
    func reserveLineHeight(_ height: CGFloat, forOverlayAt location: Int,
                           in result: NSMutableAttributedString) {
        guard location < result.length else { return }
        let ns = result.string as NSString
        // The enclosing paragraph (between newlines): minimumLineHeight is a
        // paragraph attribute, and for the heading/inline cases the math sits
        // on a single line, so this grows exactly the line that needs it.
        let para = ns.paragraphRange(for: NSRange(location: location, length: 0))
        let base = (result.attribute(.paragraphStyle, at: location, effectiveRange: nil)
            as? NSParagraphStyle) ?? bodyParagraphStyle
        guard height > base.minimumLineHeight else { return }
        let ps = (base.mutableCopy() as! NSMutableParagraphStyle)
        ps.minimumLineHeight = height
        result.addAttribute(.paragraphStyle, value: ps, range: para)
    }
}

// MARK: - Stack Construction

public extension EditorTextView {
    /// Builds the TextKit 2 text system chain and returns the wired editor:
    ///   EditorTextStorage → NSTextContentStorage → NSTextLayoutManager
    ///   → NSTextContainer → EditorTextView
    static func makeTextKit2(frame: NSRect, containerSize: NSSize) -> EditorTextView {
        let contentStorage = NSTextContentStorage()
        contentStorage.textStorage = EditorTextStorage()

        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)

        let container = NSTextContainer(size: containerSize)
        container.widthTracksTextView = true
        layoutManager.textContainer = container

        return EditorTextView(frame: frame, textContainer: container)
    }
}
