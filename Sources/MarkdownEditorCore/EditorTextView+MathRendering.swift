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

    /// Renders a LaTeX string to an `NSTextAttachment` sized to `fontSize` and
    /// aligned to the text baseline, or `nil` if SwiftMath can't parse it (the
    /// caller then shows the raw source instead).
    func mathAttachment(latex: String, display: Bool, fontSize: CGFloat) -> NSTextAttachment? {
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
            let (error, image) = math.asImage()
            guard error == nil, let image else { return nil }

            // Typeset once more via a label to read the descent (the distance from
            // the math baseline to the bottom of the image), used for alignment.
            let label = MTMathUILabel()
            label.latex = latex
            label.fontSize = fontSize
            label.labelMode = mode
            label.layout()
            let descent = label.displayList?.descent ?? 0

            render = MathRender(image: image, descent: descent)
            mathRenderCache.setObject(render, forKey: key)
        }

        let attachment = NSTextAttachment()
        attachment.image = render.image

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
        // Drop the image so its baseline (descent above the image bottom) lands
        // on the text baseline.
        attachment.bounds = CGRect(x: 0, y: -descent, width: width, height: height)
        return attachment
    }

    /// The usable text width for one line — the text container minus its line
    /// fragment padding on both sides. Used to cap over-wide equations.
    private var availableContentWidth: CGFloat {
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
    /// only to the attachment's (first) line — a multi-line `$$…$$` block is
    /// several paragraphs in the text storage (its hidden inner lines), so
    /// padding every paragraph would multiply into a huge gap.
    func displayMathParagraphStyle(padded: Bool) -> NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.alignment = .center
        ps.lineSpacing = 0
        let pad = padded ? bodyFont.pointSize * 0.9 : 0
        ps.paragraphSpacingBefore = pad
        ps.paragraphSpacing = pad
        return ps
    }
}
