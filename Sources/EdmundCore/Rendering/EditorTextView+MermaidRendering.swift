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
        let overlay = FragmentOverlay(image: image,
                                      bounds: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        mermaidOverlayCache.setObject(overlay, forKey: key)
        return overlay
    }

    /// Replaces an inactive mermaid fence with `overlay`: the whole span goes
    /// to the hidden font (its lines collapse to near-zero height, as a
    /// multi-line `$$` block's inner lines do), the first character carries the
    /// overlay, and the first line reserves the image's height plus the
    /// display-math padding, centred.
    func styleMermaidDiagram(_ result: NSMutableAttributedString,
                             span: SyntaxHighlighter.Span,
                             overlay: FragmentOverlay) {
        guard span.fullRange.upperBound <= result.length, span.fullRange.length > 0 else { return }
        result.addAttribute(.font, value: hiddenFont, range: span.fullRange)
        result.addAttribute(.foregroundColor, value: NSColor.clear, range: span.fullRange)
        applyOverlay(overlay, anchor: NSRange(location: span.fullRange.location, length: 1), in: result)

        let ns = result.string as NSString
        result.addAttribute(.paragraphStyle, value: displayMathParagraphStyle(padded: false),
                            range: span.fullRange)
        let firstLine = NSIntersectionRange(
            ns.lineRange(for: NSRange(location: span.fullRange.location, length: 0)), span.fullRange)
        result.addAttribute(.paragraphStyle,
                            value: displayMathParagraphStyle(padded: true,
                                                             imageAscent: overlay.bounds.height,
                                                             imageDescent: 0),
                            range: firstLine)
    }
}
