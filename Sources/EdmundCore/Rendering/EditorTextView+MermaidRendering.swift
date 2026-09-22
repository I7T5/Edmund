import AppKit

// MARK: - Mermaid Diagram Rendering
//
// A ```` ```mermaid ```` fence renders as its diagram when the caret is outside
// it and as an ordinary code block when inside — the display-math treatment,
// block-shaped: a `FragmentOverlay` on the opening fence's first character,
// every other character hidden, the image's height reserved on that line.
// Nothing here is async: `MermaidRenderer.image` is JavaScriptCore + CoreSVG
// on the main actor, so the styling pass gets the picture (or nil) in the same
// call, exactly as it gets a math bitmap. Every nil — extension off, payload
// not installed, source that doesn't parse — leaves the fence styled as the
// plain code block it would be anyway, by falling through to that branch.

// Overlay geometry depends on the content width, so it is cached a step past
// the image (which `MermaidRenderer` caches on its own).
nonisolated(unsafe) private let mermaidOverlayCache = NSCache<NSString, FragmentOverlay>()

extension EditorTextView {

    /// The diagram for `source` sized to the text width, or nil when there is
    /// nothing to draw. Palette is the editor's own page and ink, resolved
    /// against this view's appearance the way `mathOverlay` resolves its colour,
    /// so a diagram sits on the editor page rather than on Read mode's.
    func mermaidOverlay(source: String) -> FragmentOverlay? {
        var style = MermaidStyle(backgroundHex: "#FFFFFF", foregroundHex: "#000000")
        effectiveAppearance.performAsCurrentDrawingAppearance {
            style = MermaidStyle(backgroundHex: editorBackgroundColor.hexString,
                                 foregroundHex: foregroundColor.hexString)
        }
        guard let image = MermaidRenderer.shared.image(source: source, style: style) else { return nil }

        var size = image.size
        let maxWidth = availableContentWidth
        if maxWidth > 0, size.width > maxWidth {
            size = NSSize(width: maxWidth, height: size.height * maxWidth / size.width)
        }
        // No device-grid snapping (cf. `mathOverlay`): the image is vector-backed,
        // so drawing it at a fractional size re-rasterises rather than resamples.
        let key = String(format: "%@|%@|%.3f|%.3f|%@", style.backgroundHex, style.foregroundHex,
                         size.width, size.height, source) as NSString
        if let cached = mermaidOverlayCache.object(forKey: key) { return cached }
        // `bounds.minY` is the drawing's bottom relative to the baseline, so
        // -height hangs the whole picture *below* the anchor's line rather than
        // above it. That is what keeps the anchor line itself a normal text
        // line — see `styleMermaidDiagram`.
        let overlay = FragmentOverlay(
            image: image,
            bounds: CGRect(x: 0, y: -size.height, width: size.width, height: size.height))
        mermaidOverlayCache.setObject(overlay, forKey: key)
        return overlay
    }

    /// Replaces an inactive mermaid fence with `overlay`: the whole span goes
    /// to the hidden font (its lines collapse to near-zero height, as a
    /// multi-line `$$` block's inner lines do) and the first character carries
    /// the picture, which hangs below that line.
    ///
    /// The height is reserved as a decoration's `bottomPad` — which grows the
    /// *fragment*, keeping the space clickable and the next block clear — and
    /// deliberately **not** as a tall `minimumLineHeight` the way display math
    /// does it. A line box as tall as a diagram takes three things with it:
    /// AppKit draws the caret the full height of the line it lands on (a
    /// 300 pt bar the moment you click the picture), the line number centres on
    /// that line's baseline and so sits at the diagram's bottom edge rather
    /// than beside its first line, and the anchor can only be centred or not at
    /// all. Keeping the anchor a normal code line and hanging the image off its
    /// baseline gives a normal caret, a number at the top, and a left edge that
    /// lines up with the text column.
    func styleMermaidDiagram(_ result: NSMutableAttributedString,
                             span: SyntaxHighlighter.Span,
                             overlay: FragmentOverlay) {
        guard span.fullRange.upperBound <= result.length, span.fullRange.length > 0 else { return }
        result.addAttribute(.font, value: hiddenFont, range: span.fullRange)
        result.addAttribute(.foregroundColor, value: NSColor.clear, range: span.fullRange)
        applyOverlay(overlay, anchor: NSRange(location: span.fullRange.location, length: 1), in: result)

        let ns = result.string as NSString
        let firstLine = NSIntersectionRange(
            ns.lineRange(for: NSRange(location: span.fullRange.location, length: 0)), span.fullRange)
        guard firstLine.length > 0 else { return }

        let base = (result.attribute(.paragraphStyle, at: span.fullRange.location,
                                     effectiveRange: nil) as? NSParagraphStyle) ?? bodyParagraphStyle
        // Every source line collapses to nothing — the picture stands in for
        // all of them. Each is its own layout fragment, so a line height left
        // on them would stack up as blank rows (and numbered ones) under the
        // diagram.
        let collapsed = (base.mutableCopy() as! NSMutableParagraphStyle)
        collapsed.minimumLineHeight = 0
        collapsed.lineSpacing = 0
        collapsed.paragraphSpacingBefore = 0
        collapsed.paragraphSpacing = 0
        result.addAttribute(.paragraphStyle, value: collapsed, range: span.fullRange)

        // …except the anchor's own line, the diagram's top margin and the only
        // line here with height: it is where the caret and the line number live.
        let anchor = (collapsed.mutableCopy() as! NSMutableParagraphStyle)
        anchor.minimumLineHeight = NSLayoutManager().defaultLineHeight(for: codeBlockFont)
        anchor.paragraphSpacingBefore = base.paragraphSpacingBefore
        result.addAttribute(.paragraphStyle, value: anchor, range: firstLine)

        // An invisible box: it paints nothing, and exists only so its
        // `bottomPad` reserves the picture's height inside the fragment.
        let spacer = BlockDecoration(.box(background: .clear, borderColor: nil,
                                          borderEdges: [], borderWidth: 0,
                                          bottomPad: overlay.bounds.height + Self.mermaidBottomGap))
        result.addAttribute(.blockDecoration, value: spacer, range: firstLine)
    }

    /// Air below the picture, before whatever follows the fence.
    private static let mermaidBottomGap: CGFloat = 8
}
