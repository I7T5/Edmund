import AppKit
import SwiftMath

/// Rendered math images are cached so we don't re-rasterize on every keystroke
/// or recompose. The key encodes everything that affects the pixels: latex,
/// display vs inline, font size, and the resolved text color (light/dark).
// NSCache is internally thread-safe; `nonisolated(unsafe)` opts it out of the
// Swift 6 Sendable check (in practice it's only touched on the main actor).
nonisolated(unsafe) private let mathImageCache = NSCache<NSString, NSImage>()

extension EditorTextView {

    /// Renders a LaTeX string to an `NSTextAttachment`, or `nil` if SwiftMath
    /// can't parse it (the caller then shows the raw source instead).
    func mathAttachment(latex: String, display: Bool) -> NSTextAttachment? {
        let fontSize = bodyFont.pointSize

        // Resolve the (dynamic) text color against this view's appearance so the
        // math is rendered in the right shade for light/dark — and so the cache
        // key differs between the two.
        var color = foregroundColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = self.foregroundColor.usingColorSpace(.deviceRGB) ?? self.foregroundColor
        }
        let tag = String(format: "%.0f,%.3f,%.3f,%.3f,%.3f", fontSize,
                         color.redComponent, color.greenComponent,
                         color.blueComponent, color.alphaComponent)
        let key = "\(display ? "D" : "I")|\(tag)|\(latex)" as NSString

        let image: NSImage
        if let cached = mathImageCache.object(forKey: key) {
            image = cached
        } else {
            let math = MTMathImage(latex: latex, fontSize: fontSize,
                                   textColor: color, labelMode: display ? .display : .text)
            let (error, rendered) = math.asImage()
            guard error == nil, let rendered else { return nil }
            mathImageCache.setObject(rendered, forKey: key)
            image = rendered
        }

        let attachment = NSTextAttachment()
        attachment.image = image
        // Nudge down so inline math sits roughly on the text baseline.
        attachment.bounds = CGRect(x: 0, y: -fontSize * 0.2,
                                   width: image.size.width, height: image.size.height)
        return attachment
    }
}
