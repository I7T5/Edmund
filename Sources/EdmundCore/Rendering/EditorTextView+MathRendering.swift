import AppKit
import SwiftMath

/// A rendered equation: the image plus its typesetting descent, which we need to
/// sit the math on the surrounding text's baseline.
private final class MathRender {
    let image: NSImage
    let descent: CGFloat
    init(image: NSImage, descent: CGFloat) {
        self.image = image
        self.descent = descent
    }
}

/// Rendered math is cached so we don't re-typeset on every keystroke or
/// recompose. The key encodes everything that affects the pixels/metrics:
/// latex, display vs inline, font size, and the resolved text color.
// NSCache is internally thread-safe; `nonisolated(unsafe)` opts it out of the
// Swift 6 Sendable check (in practice it's only touched on the main actor).
nonisolated(unsafe) private let mathRenderCache = NSCache<NSString, MathRender>()

extension EditorTextView {

    /// Renders a LaTeX string to a `FragmentOverlay` sized to `fontSize` and
    /// aligned to the text baseline, or `nil` if SwiftMath can't parse it (the
    /// caller then shows the raw source instead).
    func mathOverlay(latex: String, display: Bool, fontSize: CGFloat) -> FragmentOverlay? {
        // Resolve the (dynamic) text color against this view's appearance so the
        // math renders in the right shade for light/dark — and so the cache key
        // differs between the two.
        var color = foregroundColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = self.foregroundColor.usingColorSpace(.deviceRGB) ?? self.foregroundColor
        }
        let tag = String(format: "%.1f,%.3f,%.3f,%.3f,%.3f", fontSize,
                         color.redComponent, color.greenComponent,
                         color.blueComponent, color.alphaComponent)
        let key = "\(display ? "D" : "I")|\(tag)|\(latex)" as NSString

        let render: MathRender
        if let cached = mathRenderCache.object(forKey: key) {
            render = cached
        } else {
            let mode: MTMathUILabelMode = display ? .display : .text
            let math = MTMathImage(latex: latex, fontSize: fontSize, textColor: color, labelMode: mode)
            // SwiftMath sizes the image to the exact typographic ascent+descent,
            // which crops a glyph's ink overshoot below the baseline — the bottom
            // of a lone `x`/`c` sits flush on the image edge and renders clipped.
            // A small content inset gives the rasterizer room so the full glyph is
            // drawn; it's folded into the descent below so alignment is unchanged.
            let insetPad: CGFloat = 2
            math.contentInsets = MTEdgeInsets(top: insetPad, left: 0, bottom: insetPad, right: 0)
            let (error, image) = math.asImage()
            guard error == nil, let image else { return nil }

            // Typeset once more via a label to read ascent/descent, then compute
            // the baseline's distance from the image bottom the way SwiftMath's
            // asImage does — including its `height < fontSize/2` clamp, which
            // re-centers small glyphs (a lone x/c/n). Ignoring the clamp left
            // those a pixel below the surrounding text baseline.
            let label = MTMathUILabel()
            label.latex = latex
            label.fontSize = fontSize
            label.labelMode = mode
            label.layout()
            let asc = label.displayList?.ascent ?? 0
            let desc = label.displayList?.descent ?? 0
            let clamped = max(asc + desc, fontSize / 2)
            let descent = (asc + desc - clamped) / 2 + desc + insetPad

            render = MathRender(image: image, descent: descent)
            mathRenderCache.setObject(render, forKey: key)
        }

        var width = render.image.size.width
        var height = render.image.size.height
        var descent = render.descent
        // Interim until SwiftMath line-wrapping ships: if the equation is wider
        // than the text area, scale it down to fit (otherwise leave it natural
        // size). The baseline descent scales with it.
        let maxWidth = availableContentWidth
        if maxWidth > 0, width > maxWidth {
            let scale = maxWidth / width
            width *= scale
            height *= scale
            descent *= scale
        }
        // The rendered image's baseline sits exactly one device pixel below the
        // surrounding text baseline (measured constant across font sizes — it's a
        // fixed rasterization offset, not a size-dependent rounding). Lift the
        // image by one device pixel so the math rests on the text baseline. Done
        // here, not in the cached descent, so it tracks the window's scale if it
        // moves between a Retina and a non-Retina display.
        let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        descent -= 1 / backingScale
        // Drop the image so its baseline (descent above the image bottom) lands
        // on the text baseline.
        return FragmentOverlay(image: render.image,
                               bounds: CGRect(x: 0, y: -descent, width: width, height: height))
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
