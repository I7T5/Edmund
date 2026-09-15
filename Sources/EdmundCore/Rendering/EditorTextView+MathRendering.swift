import AppKit

/// Built overlays are cached so we don't rebuild one on every keystroke or
/// recompose. The rendered *image* is already cached by the active engine
/// (`MathRendering`); this caches the second step — the overlay wrapping it —
/// whose geometry also depends on the container width and backing scale, so
/// the key carries those too.
// NSCache is internally thread-safe; `nonisolated(unsafe)` opts it out of the
// Swift 6 Sendable check (in practice it's only touched on the main actor).
nonisolated(unsafe) private let mathOverlayCache = NSCache<NSString, FragmentOverlay>()

extension EditorTextView {

    /// Renders a LaTeX string to a `FragmentOverlay` sized to `fontSize` and
    /// aligned to the text baseline, or `nil` if the active math engine can't
    /// parse it (the caller then shows the raw source instead).
    func mathOverlay(latex: String, display: Bool, fontSize: CGFloat) -> FragmentOverlay? {
        // Resolve the (dynamic) text color against this view's appearance so the
        // math renders in the right shade for light/dark — and so the render
        // cache (keyed by color) differs between the two.
        var color = foregroundColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = self.foregroundColor.usingColorSpace(.deviceRGB) ?? self.foregroundColor
        }
        guard let rendered = MathRendering.shared.render(latex: latex, displayMode: display,
                                                          pointSize: fontSize, color: color) else {
            return nil
        }

        var width = rendered.image.size.width
        var height = rendered.image.size.height
        var descent = rendered.descent
        let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        // Interim until SwiftMath line-wrapping ships: if the equation is wider
        // than the text area, scale it down to fit (otherwise leave it natural
        // size). The baseline descent scales with it.
        let maxWidth = availableContentWidth
        if maxWidth > 0, width > maxWidth {
            let scale = maxWidth / width
            width *= scale
            height *= scale
            descent *= scale
        } else {
            // A math bitmap is rasterized at the backing scale, but its NSImage
            // *point* size is computed independently of its rounded pixel count
            // (RaTeX: 109 px shown at 54.264 pt — a ratio of 2.009, not 2). So
            // drawing it at `image.size` covers a fractional number of device
            // pixels and Core Graphics resamples the blit: the same ink spreads
            // over ~39% more device pixels at 37% partial coverage (vs 14%),
            // which is why equations looked slightly bolder here than the
            // identical image in Read mode — that path already pins its <img>
            // to the PNG's exact pixel count for this reason (DocumentHTML
            // .fillMath). Snap the draw size onto the device grid so the blit is
            // 1:1. The *position* is snapped where it's drawn (see
            // `deviceAligned` in EditorTextView+TextKit2): both are needed —
            // either misalignment alone resamples just as badly.
            let snapped = (height * backingScale).rounded() / backingScale
            descent *= snapped / height
            width = (width * backingScale).rounded() / backingScale
            height = snapped
        }
        // The rendered image's baseline sits exactly one device pixel below the
        // surrounding text baseline (measured constant across font sizes — it's a
        // fixed rasterization offset, not a size-dependent rounding). Lift the
        // image by one device pixel so the math rests on the text baseline. Done
        // here, not in the cached descent, so it tracks the window's scale if it
        // moves between a Retina and a non-Retina display.
        descent -= 1 / backingScale
        // Drop the image so its baseline (descent above the image bottom) lands
        // on the text baseline.
        // The engine id is part of the key so enabling/disabling a math
        // extension (which swaps the active renderer) can't serve overlays
        // built by the previous engine.
        let key = String(
            format: "%@|%@|%.1f|%.3f,%.3f,%.3f,%.3f|%.3f|%.3f|%.3f|%@",
            MathRendering.shared.active.id,
            display ? "D" : "I",
            fontSize,
            color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent,
            width, height, descent,
            latex
        ) as NSString
        if let cached = mathOverlayCache.object(forKey: key) { return cached }
        let overlay = FragmentOverlay(
            image: rendered.image,
            bounds: CGRect(x: 0, y: -descent, width: width, height: height)
        )
        mathOverlayCache.setObject(overlay, forKey: key)
        return overlay
    }

    /// The usable text width for one line — the text container minus its line
    /// fragment padding on both sides. Used to cap over-wide equations (and
    /// over-wide images).
    var availableContentWidth: CGFloat {
        guard let container = textContainer else { return 0 }
        return container.containerSize.width - 2 * container.lineFragmentPadding
    }

    // MARK: - Raw LaTeX Source (shown when the cursor is inside the math)

    /// Colors raw LaTeX source: operators/commands (`_`, `^`, `\sum`, `\cdot`,
    /// i.e. a backslash followed by letters) in the theme's math-operator color,
    /// and numbers in the math-number color. Other characters keep their color.
    func colorMathSource(_ result: NSMutableAttributedString, range: NSRange) {
        guard range.length > 0, range.upperBound <= result.length else { return }
        let ns = result.string as NSString
        let opColor = theme.mathOperatorColor
        let numColor = theme.mathNumberColor
        let backslash: unichar = 0x5C, underscore: unichar = 0x5F, caret: unichar = 0x5E

        func isAlpha(_ c: unichar) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) }
        func isDigit(_ c: unichar) -> Bool { c >= 0x30 && c <= 0x39 }

        var i = range.location
        let end = range.upperBound
        while i < end {
            let c = ns.character(at: i)
            if c == backslash {
                // Command: backslash + following letters (\sum, \cdot). A
                // backslash before a non-letter (\,, \{) colors just the pair.
                var j = i + 1
                while j < end, isAlpha(ns.character(at: j)) { j += 1 }
                let cmdEnd = j > i + 1 ? j : min(i + 2, end)
                result.addAttribute(.foregroundColor, value: opColor,
                                    range: NSRange(location: i, length: cmdEnd - i))
                i = cmdEnd
            } else if c == underscore || c == caret {
                result.addAttribute(.foregroundColor, value: opColor,
                                    range: NSRange(location: i, length: 1))
                i += 1
            } else if isDigit(c) {
                var j = i + 1
                while j < end, isDigit(ns.character(at: j)) { j += 1 }
                result.addAttribute(.foregroundColor, value: numColor,
                                    range: NSRange(location: i, length: j - i))
                i = j
            } else {
                i += 1
            }
        }
    }

    /// Centered paragraph style for display math. The vertical padding is applied
    /// only to the image's (first) line — a multi-line `$$…$$` block is
    /// several paragraphs in the text storage (its hidden inner lines), so
    /// padding every paragraph would multiply into a huge gap.
    ///
    /// `imageAscent`/`imageDescent` reserve the equation's height on that line:
    /// the line's own characters are hidden (near-zero), so without it the line
    /// collapses. They're reserved separately, not as one combined height,
    /// because of how TextKit 2 grows a line to meet `minimumLineHeight`: with
    /// the hidden anchor's near-zero natural metrics, it adds ~all of the extra
    /// height as ascent and pins the baseline at the box's bottom edge (measured
    /// empirically — a tall multi-row image split ~54/46 ascent/descent left a
    /// matching-sized gap above the equation and an overlap with the next
    /// paragraph below, since `minimumLineHeight = full height` reserved that
    /// height entirely above the baseline). Reserving only `imageAscent` in
    /// `minimumLineHeight` sits the image's top flush with the box's top instead
    /// of leaving a surplus gap, and folding `imageDescent` into the *following*
    /// spacing (rather than the line's own height) gives the part of the image
    /// that hangs below the baseline somewhere to go before the next paragraph.
    func displayMathParagraphStyle(padded: Bool, imageAscent: CGFloat = 0,
                                   imageDescent: CGFloat = 0) -> NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.alignment = .center
        ps.lineSpacing = 0
        let pad = padded ? bodyFont.pointSize * 0.9 : 0
        ps.paragraphSpacingBefore = pad
        ps.paragraphSpacing = pad + imageDescent
        ps.minimumLineHeight = imageAscent
        return ps
    }
}
