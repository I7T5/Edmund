import AppKit
import SwiftMath

// MARK: - DocumentHTML
//
// Assembles the full, self-contained HTML document for Read mode and PDF export:
// the `HTMLRenderer` body, the `HTMLTheme` stylesheet, and a second pass that
// fills the renderer's placeholder elements with inlined assets (SwiftMath
// glyphs and local images) as data URIs. Callout/checkbox icons are inline
// Lucide SVGs emitted by `HTMLRenderer` (no asset pass needed). Inlining keeps
// the document self-contained — the webview needs no file/network access (§G).
@MainActor
enum DocumentHTML {

    /// Builds a complete `<!DOCTYPE html>…` document for `markdown`. `baseURL` is
    /// the document's directory, used to resolve relative image paths for inlining.
    static func full(markdown: String,
                     theme: EditorTheme,
                     callouts: [String: CalloutStyle],
                     dark: Bool,
                     baseURL: URL? = nil,
                     options: ReadRenderOptions = .default) -> String {
        var body = HTMLRenderer.render(markdown: markdown, options: options)
        body = fillMath(body, theme: theme, dark: dark)
        body = fillImages(body, baseURL: baseURL, options: options)
        let css = HTMLTheme.css(theme, callouts: callouts, dark: dark,
                                maxContentWidthPoints: options.maxContentWidthPoints)
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

    // MARK: Images (local → inlined data URI; remote → off by default)

    private static let imagePattern =
        "<img class=\"md-image\" data-src=\"([^\"]*)\" alt=\"([^\"]*)\">"

    /// Resolves each `md-image` placeholder: local/relative paths are read and
    /// inlined as a data URI (self-contained, no file access needed at render
    /// time); a `data:` source passes through; remote `http(s)` sources load
    /// only when `options.allowRemoteImages` is set, else the alt text shows.
    private static func fillImages(_ html: String, baseURL: URL?,
                                   options: ReadRenderOptions) -> String {
        var cache: [String: String] = [:]   // resolved path → data URI
        return replaceMatches(html, pattern: imagePattern) { groups in
            let src = unescapeAttr(groups[1])
            let alt = groups[2]   // already attribute-escaped by the renderer
            func placeholder() -> String { "<img class=\"md-image\" alt=\"\(alt)\">" }

            if src.isEmpty { return placeholder() }
            let lower = src.lowercased()
            if lower.hasPrefix("data:") {
                return "<img class=\"md-image\" src=\"\(HTMLRenderer.attr(src))\" alt=\"\(alt)\">"
            }
            if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
                guard options.allowRemoteImages else { return placeholder() }
                return "<img class=\"md-image\" src=\"\(HTMLRenderer.attr(src))\" alt=\"\(alt)\">"
            }
            // Local: resolve against the document directory, read, inline.
            guard let fileURL = resolveLocalImage(src, baseURL: baseURL) else { return placeholder() }
            let uri: String
            if let cached = cache[fileURL.path] {
                uri = cached
            } else {
                uri = imageDataURI(fileURL) ?? ""
                cache[fileURL.path] = uri
            }
            guard !uri.isEmpty else { return placeholder() }
            return "<img class=\"md-image\" src=\"\(uri)\" alt=\"\(alt)\">"
        }
    }

    /// Resolves a local image `path` to a file URL: absolute / `~` / `file:`
    /// load directly; a relative path resolves against the document's directory.
    private static func resolveLocalImage(_ path: String, baseURL: URL?) -> URL? {
        if let url = URL(string: path), url.scheme == "file" { return url }
        // A markdown image destination may be percent-encoded (e.g. `%20`).
        let decoded = path.removingPercentEncoding ?? path
        if decoded.hasPrefix("/") { return URL(fileURLWithPath: decoded) }
        if decoded.hasPrefix("~") { return URL(fileURLWithPath: (decoded as NSString).expandingTildeInPath) }
        guard let baseURL else { return nil }
        let resolved = baseURL.appendingPathComponent(decoded)
        return FileManager.default.fileExists(atPath: resolved.path) ? resolved : nil
    }

    /// Reads an image file and returns a `data:` URI, with the MIME type guessed
    /// from the file extension (covers the common web image formats).
    private static func imageDataURI(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let mime: String
        switch url.pathExtension.lowercased() {
        case "png":          mime = "image/png"
        case "jpg", "jpeg":  mime = "image/jpeg"
        case "gif":          mime = "image/gif"
        case "svg":          mime = "image/svg+xml"
        case "webp":         mime = "image/webp"
        case "bmp":          mime = "image/bmp"
        case "tiff", "tif":  mime = "image/tiff"
        default:             mime = "application/octet-stream"
        }
        return "data:\(mime);base64,\(data.base64EncodedString())"
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
}
