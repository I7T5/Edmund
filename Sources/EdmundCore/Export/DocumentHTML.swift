import AppKit
import SwiftMath

// MARK: - DocumentHTML
//
// Assembles the full, self-contained HTML document for Read mode and PDF export:
// the `HTMLRenderer` body, the `HTMLTheme` stylesheet, and a second pass that
// fills the renderer's placeholder elements with inlined assets (SF-Symbol
// callout icons and SwiftMath glyphs) as data URIs. Inlining everything keeps
// the document self-contained — the webview needs no file/network access (§G).
@MainActor
enum DocumentHTML {

    /// Builds a complete `<!DOCTYPE html>…` document for `markdown`.
    static func full(markdown: String,
                     theme: EditorTheme,
                     callouts: [String: CalloutStyle],
                     dark: Bool,
                     options: ReadRenderOptions = .default) -> String {
        var body = HTMLRenderer.render(markdown: markdown, options: options)
        body = fillCalloutIcons(body, callouts: callouts, dark: dark)
        body = fillMath(body, theme: theme, dark: dark)
        let css = HTMLTheme.css(theme, callouts: callouts, dark: dark)
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        \(css)
        </style></head>
        <body><div class="page">\(body)</div></body></html>
        """
    }

    // MARK: Callout icons (SF Symbol → tinted PNG data URI)

    private static let iconPattern =
        "<span class=\"callout-icon\" data-symbol=\"([^\"]*)\" data-type=\"([^\"]*)\"></span>"

    private static func fillCalloutIcons(_ html: String,
                                         callouts: [String: CalloutStyle],
                                         dark: Bool) -> String {
        var cache: [String: String] = [:]   // "symbol|hex" → data URI
        return replaceMatches(html, pattern: iconPattern) { groups in
            let symbol = unescapeAttr(groups[1])
            let type = unescapeAttr(groups[2])
            let hex = (callouts[type] ?? Callout.defaultStyles[type])?.accentHex(dark: dark) ?? "#888888"
            let key = "\(symbol)|\(hex)"
            let uri: String
            if let cached = cache[key] {
                uri = cached
            } else {
                uri = iconDataURI(symbol: symbol, hex: hex) ?? ""
                cache[key] = uri
            }
            guard !uri.isEmpty else { return "<span class=\"callout-icon\"></span>" }
            return "<span class=\"callout-icon\"><img src=\"\(uri)\" alt=\"\"></span>"
        }
    }

    /// Renders an SF Symbol tinted to `hex` and returns a PNG data URI (@2x).
    ///
    /// QUIRK: tint in **sRGB** via a `CGColorSpace.sRGB` CGContext and tag the
    /// PNG sRGB. `NSColor(hex:)` creates a *calibrated* RGB color, which rounds
    /// trips through a device-RGB bitmap context and shifts saturated hues —
    /// most visibly TIP's teal (`#00BFBC`) renders noticeably greener, making
    /// the icon and CSS title text disagree. Using sRGB throughout keeps them
    /// pixel-matched because CSS `#RRGGBB` is interpreted as sRGB by WebKit.
    private static func iconDataURI(symbol: String, hex: String) -> String? {
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
              let (r, g, b) = rgbComponents(hex) else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        let sized = base.withSymbolConfiguration(config) ?? base
        let scale: CGFloat = 2
        let w = Int((sized.size.width * scale).rounded())
        let h = Int((sized.size.height * scale).rounded())
        guard w > 0, h > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        let rect = NSRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
        let gctx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gctx
        sized.draw(in: rect)                                  // template glyph alpha
        ctx.setBlendMode(.sourceAtop)                         // tint where it drew
        ctx.setFillColor(CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
                                 blue: CGFloat(b) / 255, alpha: 1))
        ctx.fill(rect)
        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64,\(data.base64EncodedString())"
    }

    // MARK: Math (SwiftMath → PNG data URI)

    private static let inlineMathPattern = "<span class=\"math-inline\" data-tex=\"([^\"]*)\"></span>"
    private static let displayMathPattern = "<div class=\"math-display\" data-tex=\"([^\"]*)\"></div>"

    private static func fillMath(_ html: String, theme: EditorTheme, dark: Bool) -> String {
        let color = NSColor(hex: dark ? "#e6e6e6" : "#1a1a1a") ?? .textColor
        var out = replaceMatches(html, pattern: displayMathPattern) { groups in
            let tex = unescapeAttr(groups[1])
            guard let r = mathImage(latex: tex, display: true,
                                    fontSize: theme.fontSize, color: color),
                  let data = pngData(r.image, scale: 2) else {
                return "<div class=\"math-display\"><code>\(HTMLRenderer.escape(tex))</code></div>"
            }
            let uri = "data:image/png;base64,\(data.base64EncodedString())"
            return "<div class=\"math-display\"><img class=\"math\" style=\"height:\(fmt(r.image.size.height))px\" src=\"\(uri)\" alt=\"\(HTMLRenderer.attr(tex))\"></div>"
        }
        out = replaceMatches(out, pattern: inlineMathPattern) { groups in
            let tex = unescapeAttr(groups[1])
            guard let r = mathImage(latex: tex, display: false,
                                    fontSize: theme.fontSize, color: color),
                  let data = pngData(r.image, scale: 2) else {
                return "<code>\(HTMLRenderer.escape(tex))</code>"
            }
            let uri = "data:image/png;base64,\(data.base64EncodedString())"
            // Drop the image so its baseline (descent above its bottom) lands on
            // the text baseline — same alignment the editor computes.
            return "<img class=\"math math-inline\" style=\"height:\(fmt(r.image.size.height))px; vertical-align:\(fmt(-r.descent))px\" src=\"\(uri)\" alt=\"\(HTMLRenderer.attr(tex))\">"
        }
        return out
    }

    /// Renders LaTeX with SwiftMath to an image + baseline descent. Standalone
    /// (no `EditorTextView`) mirror of `EditorTextView.mathOverlay`'s core.
    private static func mathImage(latex: String, display: Bool,
                                  fontSize: CGFloat, color: NSColor)
        -> (image: NSImage, descent: CGFloat)? {
        let mode: MTMathUILabelMode = display ? .display : .text
        let math = MTMathImage(latex: latex, fontSize: fontSize, textColor: color, labelMode: mode)
        let insetPad: CGFloat = 2
        math.contentInsets = MTEdgeInsets(top: insetPad, left: 0, bottom: insetPad, right: 0)
        let (error, image) = math.asImage()
        guard error == nil, let image else { return nil }

        let label = MTMathUILabel()
        label.latex = latex
        label.fontSize = fontSize
        label.labelMode = mode
        label.layout()
        let asc = label.displayList?.ascent ?? 0
        let desc = label.displayList?.descent ?? 0
        let clamped = max(asc + desc, fontSize / 2)
        let descent = (asc + desc - clamped) / 2 + desc + insetPad
        return (image, descent)
    }

    // MARK: Bitmap / escaping helpers

    /// Rasterizes an `NSImage` to PNG `Data` at `scale`× its point size.
    private static func pngData(_ image: NSImage, scale: CGFloat) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int((size.width * scale).rounded()),
                pixelsHigh: Int((size.height * scale).rounded()),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// Reverses the HTML-attribute escaping done by `HTMLRenderer.attr` so the
    /// raw LaTeX/symbol can be recovered from a placeholder attribute.
    private static func unescapeAttr(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
         .replacingOccurrences(of: "&gt;", with: ">")
         .replacingOccurrences(of: "&quot;", with: "\"")
         .replacingOccurrences(of: "&#39;", with: "'")
         .replacingOccurrences(of: "&amp;", with: "&")   // last, by convention
    }

    /// Finds every match of `pattern` and replaces it with `transform(groups)`,
    /// where `groups[0]` is the whole match. Replaces back-to-front so ranges
    /// stay valid.
    private static func replaceMatches(_ html: String, pattern: String,
                                       _ transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.dotMatchesLineSeparators]) else { return html }
        let ns = html as NSString
        let result = NSMutableString(string: html)
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        for m in matches.reversed() {
            var groups: [String] = []
            for i in 0..<m.numberOfRanges {
                let r = m.range(at: i)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            result.replaceCharacters(in: m.range(at: 0), with: transform(groups))
        }
        return result as String
    }

    private static func fmt(_ v: CGFloat) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    /// Parses "#RRGGBB" (or "RRGGBB") into 0–255 components.
    private static func rgbComponents(_ hex: String) -> (Int, Int, Int)? {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let rgb = UInt64(h, radix: 16) else { return nil }
        return (Int((rgb >> 16) & 0xFF), Int((rgb >> 8) & 0xFF), Int(rgb & 0xFF))
    }
}
