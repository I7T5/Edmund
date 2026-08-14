import AppKit

// MARK: - DocumentHTML
//
// Assembles the full, self-contained HTML document for Read mode and PDF export:
// the `HTMLRenderer` body, the `HTMLTheme` stylesheet, and a second pass that
// fills the renderer's placeholder elements with inlined assets (math
// glyphs and local images) as data URIs. Callout/checkbox icons are inline
// Lucide SVGs emitted by `HTMLRenderer` (no asset pass needed). Inlining keeps
// the document self-contained — the webview needs no file/network access.
// Raw HTML in the markdown passes through per GFM, filtered by
// `HTMLRenderer.filterRawHTML` (tagfilter + hardening); the page also carries a
// `script-src 'none'` CSP meta as defense-in-depth (§G, ARCHITECTURE §10).
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
        <meta http-equiv="Content-Security-Policy" content="script-src 'none'">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        \(css)
        </style></head>
        <body><div class="page">\(body)</div></body></html>
        """
    }

    // MARK: Math (active engine → PNG data URI)

    private static let inlineMathPattern = "<span class=\"math-inline\" data-tex=\"([^\"]*)\"></span>"
    // Group 1 is the block's `edmund-l<N>` source-line anchor (see
    // `HTMLRenderer.addingAnchorID`), when the display-math div is a top-level
    // block — carried through into the replacement so the anchor survives the
    // asset-fill pass.
    private static let displayMathPattern = "<div( id=\"[^\"]*\")? class=\"math-display\" data-tex=\"([^\"]*)\"></div>"
    // A `$$…$$` embedded in a prose line: display-mode rendering, but flowed
    // inline like `$…$` (matches the editor). Distinct class from the block div.
    private static let displayInlineMathPattern = "<span class=\"math-display-inline\" data-tex=\"([^\"]*)\"></span>"

    private static func fillMath(_ html: String, theme: EditorTheme, dark: Bool) -> String {
        // Same ink as the editor draws its equations in — one definition for both
        // modes (EditorTheme.bodyTextColor). Resolved against `dark` rather than
        // the current appearance because an export can target either.
        let color = EditorTheme.bodyTextColorResolved(dark: dark)
        var out = replaceMatches(html, pattern: displayMathPattern) { groups in
            let id = groups[1]
            let tex = unescapeAttr(groups[2])
            guard let r = MathRendering.shared.render(latex: tex, displayMode: true,
                                                      pointSize: theme.fontSize, color: color),
                  let png = pngData(r.image, scale: 2) else {
                return "<div\(id) class=\"math-display\"><code>\(HTMLRenderer.escape(tex))</code></div>"
            }
            let uri = "data:image/png;base64,\(png.data.base64EncodedString())"
            return "<div\(id) class=\"math-display\"><img class=\"math\" style=\"width:\(fmt(png.cssWidth))px; height:\(fmt(png.cssHeight))px\" src=\"\(uri)\" alt=\"\(HTMLRenderer.attr(tex))\"></div>"
        }
        out = replaceMatches(out, pattern: inlineMathPattern) { groups in
            let tex = unescapeAttr(groups[1])
            guard let r = MathRendering.shared.render(latex: tex, displayMode: false,
                                                      pointSize: theme.fontSize, color: color),
                  let png = pngData(r.image, scale: 2) else {
                return "<code>\(HTMLRenderer.escape(tex))</code>"
            }
            let uri = "data:image/png;base64,\(png.data.base64EncodedString())"
            // Explicit width AND height, derived from the PNG's own pixel
            // dimensions (not independently rounded from the NSImage's point
            // size) — guarantees an exact native-pixel-to-CSS-pixel ratio, so
            // the browser scales the bitmap by precisely 2x with no resampling.
            // A width/height that's merely "close" to 2x (e.g. 91 native px
            // shown at a declared 45px — ratio 2.02, not 2.0) still forces a
            // slight resample, which measurably thinned 1-2px strokes like the
            // "=" sign's bars (confirmed via connected-component pixel
            // measurement, not guessed). `vertical-align` is a position, not a
            // size, so rounding it to a whole pixel (separately) still avoids
            // the sub-pixel compositing blur that caused — same reasoning,
            // different axis.
            return "<img class=\"math math-inline\" style=\"width:\(fmt(png.cssWidth))px; height:\(fmt(png.cssHeight))px; vertical-align:\(fmt(-r.descent.rounded()))px\" src=\"\(uri)\" alt=\"\(HTMLRenderer.attr(tex))\">"
        }
        out = replaceMatches(out, pattern: displayInlineMathPattern) { groups in
            let tex = unescapeAttr(groups[1])
            // Display math embedded in a prose line still gets its own centered
            // block (a `<span>` promoted to display:block, since the placeholder
            // sits inside a `<p>` where a `<div>` would be invalid). The
            // paragraph's text keeps flowing above and below it.
            guard let r = MathRendering.shared.render(latex: tex, displayMode: true,
                                                      pointSize: theme.fontSize, color: color),
                  let png = pngData(r.image, scale: 2) else {
                return "<span class=\"math-display-block\"><code>\(HTMLRenderer.escape(tex))</code></span>"
            }
            let uri = "data:image/png;base64,\(png.data.base64EncodedString())"
            return "<span class=\"math-display-block\"><img class=\"math\" style=\"width:\(fmt(png.cssWidth))px; height:\(fmt(png.cssHeight))px\" src=\"\(uri)\" alt=\"\(HTMLRenderer.attr(tex))\"></span>"
        }
        return out
    }

    // MARK: Images (local → inlined data URI; remote → off by default)

    // Groups 3/4 are optional declared dimensions from an HTML `<img>` tag
    // (captured with their leading space so they re-emit verbatim).
    private static let imagePattern =
        "<img class=\"md-image\" data-src=\"([^\"]*)\" alt=\"([^\"]*)\"( width=\"[0-9]+\")?( height=\"[0-9]+\")?>"

    /// Resolves each `md-image` placeholder: local/relative paths are read and
    /// inlined as a data URI (self-contained, no file access needed at render
    /// time); a `data:` source passes through; remote `https` sources load only
    /// when `options.allowRemoteImages` is set. Anything that can't be shown
    /// gets a visible icon + reason (`ImageLoadFailure`, shared with Edit
    /// mode's inline preview) instead of silently showing nothing.
    private static func fillImages(_ html: String, baseURL: URL?,
                                   options: ReadRenderOptions) -> String {
        var cache: [String: String] = [:]   // resolved path → data URI
        return replaceMatches(html, pattern: imagePattern) { groups in
            let src = unescapeAttr(groups[1])
            let alt = groups[2]   // already attribute-escaped by the renderer
            let dims = groups[3] + groups[4]   // optional ` width="N" height="N"`

            if src.isEmpty { return blockedImagePlaceholder(reason:.notFound) }
            let lower = src.lowercased()
            if lower.hasPrefix("data:") {
                return "<img class=\"md-image\" src=\"\(HTMLRenderer.attr(src))\" alt=\"\(alt)\"\(dims)>"
            }
            if lower.hasPrefix("http://") {
                return blockedImagePlaceholder(reason:.httpUnsupported)
            }
            if lower.hasPrefix("https://") {
                guard options.allowRemoteImages else {
                    return blockedImagePlaceholder(reason:.blockedBySetting)
                }
                return "<img class=\"md-image\" src=\"\(HTMLRenderer.attr(src))\" alt=\"\(alt)\"\(dims)>"
            }
            // Local: resolve against the document directory, read, inline.
            guard let fileURL = resolveLocalImage(src, baseURL: baseURL) else {
                return blockedImagePlaceholder(reason:.notFound)
            }
            if let cached = cache[fileURL.path] {
                return "<img class=\"md-image\" src=\"\(cached)\" alt=\"\(alt)\"\(dims)>"
            }
            // `resolveLocalImage`'s absolute/`~` branches don't check existence
            // (only the relative-path branch does), so a missing file and an
            // undecodable one would otherwise fail `imageDataURI` identically —
            // check existence first so the two get distinct, accurate messages.
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return blockedImagePlaceholder(reason:.notFound)
            }
            guard let uri = imageDataURI(fileURL) else {
                return blockedImagePlaceholder(reason:.notAnImage)
            }
            cache[fileURL.path] = uri
            return "<img class=\"md-image\" src=\"\(uri)\" alt=\"\(alt)\"\(dims)>"
        }
    }

    /// A visible stand-in for an image that can't be shown: an icon plus a
    /// short reason, instead of just empty space.
    private static func blockedImagePlaceholder(reason: ImageLoadFailure) -> String {
        let icon = LucideIcons.inlineSVG("image-off") ?? ""
        return "<span class=\"md-image-blocked\">\(icon)<span>\(reason.label)</span></span>"
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
    /// from the file extension (covers the common web image formats). Decodes
    /// the bytes first (discarding the result) so a file that merely has an
    /// image extension but isn't actually image data is caught here — as
    /// "Not an image" — rather than silently inlining garbage the browser
    /// then fails to render with no explanation.
    private static func imageDataURI(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), NSImage(data: data) != nil else { return nil }
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

    /// A rasterized PNG plus the CSS `width`/`height` (`pixelSize / scale`)
    /// that exactly matches it — declaring anything else forces WebKit to
    /// resample the bitmap, which is what was thinning 1-2px strokes.
    private struct PNGResult {
        let data: Data
        let pixelSize: CGSize
        let scale: CGFloat
        var cssWidth: CGFloat { pixelSize.width / scale }
        var cssHeight: CGFloat { pixelSize.height / scale }
    }

    /// Rasterizes an `NSImage` to PNG `Data` at `scale`× its point size.
    /// Returns the PNG's actual pixel dimensions alongside it — those, not an
    /// independent re-rounding of `image.size * scale`, are what the caller
    /// must derive the `<img>`'s CSS size from, or the two roundings can
    /// disagree and leave a non-exact scale ratio (see `PNGResult`).
    private static func pngData(_ image: NSImage, scale: CGFloat) -> PNGResult? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let pixelsWide = Int((size.width * scale).rounded())
        let pixelsHigh = Int((size.height * scale).rounded())
        guard pixelsWide > 0, pixelsHigh > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelsWide,
                pixelsHigh: pixelsHigh,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        return PNGResult(data: data, pixelSize: CGSize(width: pixelsWide, height: pixelsHigh), scale: scale)
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
