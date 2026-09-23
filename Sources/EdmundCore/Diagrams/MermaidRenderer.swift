import AppKit
import JavaScriptCore

/// Colours a diagram is drawn with. beautiful-mermaid derives every internal
/// custom property (`--_node-fill`, `--_line`, `--_arrow`, …) from these two by
/// mixing them at fixed percentages, so passing the page's background and body
/// ink is enough to make a diagram sit in the document rather than on it.
///
/// ponytail: two fields, not the library's full seven. `line`/`accent`/`muted`/
/// `surface`/`border` are overrides for palettes that can't be derived — add
/// them if a diagram ever needs to disagree with the page, not before.
struct MermaidStyle: Hashable {
    let backgroundHex: String
    let foregroundHex: String

    /// The subset of the library's `RenderOptions` we set, as JSON.
    ///
    /// `font` is deliberately not set. The library's default (Inter) is absent
    /// on macOS, so the emitted rule falls through to `system-ui, sans-serif` —
    /// a UI face, which is what diagram labels want, and whose metrics are
    /// close to what the library's character-width heuristic was calibrated
    /// against. Passing the editor's serif body font would risk labels
    /// overflowing their boxes, since the box sizes come from that heuristic
    /// rather than from real font metrics.
    var optionsJSON: String {
        #"{"bg":"\#(backgroundHex)","fg":"\#(foregroundHex)"}"#
    }

    /// Read mode's own palette for the given appearance, so a diagram matches
    /// the page it is embedded in.
    @MainActor
    static func readMode(dark: Bool) -> MermaidStyle {
        MermaidStyle(backgroundHex: HTMLTheme.backgroundColor(dark: dark).hexString,
                     foregroundHex: EditorTheme.bodyTextColorResolved(dark: dark).hexString)
    }
}

/// Renders Mermaid diagram source to SVG using `beautiful-mermaid` (MIT), run
/// as plain JavaScript in JavaScriptCore — the "Mermaid" extension's engine.
///
/// Not ready until `install()` has downloaded, verified and evaluated the
/// payload; until then `svg(source:style:)` returns nil and every caller falls
/// back to showing the fenced code block as ordinary code. Every failure mode
/// (no network, hash mismatch, JS load error, a diagram the library can't
/// parse) degrades that same way — never crash, never install or trust an
/// unverified artifact.
///
/// Rendering is genuinely synchronous, which is the reason for hosting the
/// library here rather than in a WKWebView: `DocumentHTML.full` is a
/// synchronous `@MainActor` function, and an async renderer would force that
/// whole export path — Read mode, HTML export and PDF — to become async.
@MainActor
public final class MermaidRenderer {
    public static let shared = MermaidRenderer()

    /// Whether the user has the extension enabled. Rendering is refused when
    /// false even if the payload is installed, so disabling takes effect
    /// without an uninstall.
    public var isEnabled = false

    private let installer: ExtensionPayloadInstaller
    private var context: JSContext?
    private var render: JSValue?

    /// Rendered SVG, keyed on source + palette. Diagram layout is the
    /// expensive part (~29 ms steady-state, ~113 ms for the first one), and
    /// Read mode re-renders the whole document on every keystroke-driven
    /// refresh, so an unbounded miss rate here would be felt.
    private let cache = NSCache<NSString, NSString>()
    /// Edit mode's raster of the same SVG, keyed on the SVG string itself
    /// (already unique per source + palette). CoreSVG parsing is the cost
    /// being saved; the flattened string is never kept.
    private let imageCache = NSCache<NSString, NSImage>()

    public init(installer: ExtensionPayloadInstaller = ExtensionPayloadInstaller(payload: MermaidRelease.payload)) {
        self.installer = installer
        cache.countLimit = 64
        imageCache.countLimit = 64
    }

    /// Whether the payload is loaded and rendering can be attempted.
    public var isReady: Bool { render != nil }

    /// The installer's current state, for Settings to surface (downloading %,
    /// verifying, ready, failed → retry).
    public var installState: ExtensionInstallState {
        get async { await installer.state }
    }

    /// Downloads/verifies/installs (if needed) and evaluates the payload.
    /// Safe to call repeatedly; a no-op once already `isReady`.
    public func install() async {
        guard !isReady, let dir = try? await installer.ensureInstalled() else { return }
        load(dir: dir)
    }

    /// Unloads the library and removes its files from disk. Safe to call even
    /// if never installed.
    public func uninstall() async {
        unload()
        await installer.uninstall()
    }

    /// Evaluates the payload in a fresh `JSContext`. Internal so tests can
    /// load an unpacked payload directly, without a network fixture.
    func load(dir: URL) {
        let file = dir.appendingPathComponent(MermaidRelease.payload.sentinelFile)
        guard let source = try? String(contentsOf: file, encoding: .utf8),
              let ctx = JSContext() else {
            Log.error("Mermaid: cannot read payload at \(file.path)")
            return
        }

        ctx.exceptionHandler = { _, exception in
            Log.error("Mermaid JS exception: \(exception?.toString() ?? "unknown")")
        }
        // The payload's console shim forwards here when the host provides it.
        let logHook: @convention(block) (String, String) -> Void = { level, message in
            Log.error("Mermaid JS [\(level)]: \(message)")
        }
        ctx.setObject(logHook, forKeyedSubscript: "__edmundLog" as NSString)

        ctx.evaluateScript(source)
        guard let fn = ctx.objectForKeyedSubscript("__edmundRenderMermaid"), !fn.isUndefined else {
            Log.error("Mermaid: payload did not define __edmundRenderMermaid")
            return
        }
        context = ctx
        render = fn
        cache.removeAllObjects()
        imageCache.removeAllObjects()
    }

    func unload() {
        render = nil
        context = nil
        cache.removeAllObjects()
        imageCache.removeAllObjects()
    }

    /// Renders `source` to a self-contained SVG string, or nil when the
    /// extension is disabled, not installed, or the diagram doesn't parse.
    ///
    /// The bridge returns `"ERROR: …"` rather than throwing: an exception
    /// crossing the JSContext boundary is much harder to attribute than a
    /// sentinel string, and a malformed diagram is an expected input here, not
    /// an exceptional one.
    func svg(source: String, style: MermaidStyle) -> String? {
        guard isEnabled, let render else { return nil }

        let key = "\(style.backgroundHex)|\(style.foregroundHex)|\(source)" as NSString
        if let hit = cache.object(forKey: key) { return hit as String }

        guard let result = render.call(withArguments: [source, style.optionsJSON])?.toString(),
              result.hasPrefix("<svg") else {
            // Malformed diagram source is normal user input mid-typing; the
            // caller falls back to a plain code block. Not logged at error.
            return nil
        }
        guard Self.isSafeSVG(result) else {
            Log.error("Mermaid: rejected an SVG that failed the safety check")
            return nil
        }
        let tightened = Self.tighteningCanvas(result)
        cache.setObject(tightened as NSString, forKey: key)
        return tightened
    }

    /// Shrinks the SVG's canvas to the drawing inside it.
    ///
    /// beautiful-mermaid pads its canvas — 29 to 53 pt depending on the diagram
    /// type and even the side — which is right for a standalone picture and
    /// wrong for a block in a document: it lands as a slab of dead space above
    /// and below, it can't be styled away from outside, and it holds the
    /// drawing off the text's left edge. Both modes want the margin to come
    /// from the page (Read mode's CSS, Edit mode's line height), so it is taken
    /// off here, once, before either sees the SVG.
    ///
    /// Measured, never assumed: the padding differs per side and per diagram
    /// type, so a constant would clip one of them. The measurement rasterizes
    /// the *flattened* form through CoreSVG — which ignores the SVG's CSS
    /// `background`, so the padding is genuinely transparent and the alpha
    /// channel is the whole test. The flattened form's ink can sit a couple of
    /// points below WebKit's (folding `dy` moves a baseline), which the point
    /// of air below covers.
    ///
    /// Returns the SVG unchanged if anything about it is unexpected — a canvas
    /// that is already tight, an unreadable viewBox, a diagram that drew
    /// nothing.
    private static func tighteningCanvas(_ svg: String) -> String {
        guard let viewBox = firstMatch(#"viewBox="([\d.\-]+) ([\d.\-]+) ([\d.]+) ([\d.]+)""#, in: svg),
              let x = Double(viewBox[1]), let y = Double(viewBox[2]),
              let width = Double(viewBox[3]), let height = Double(viewBox[4]),
              width > 0, height > 0,
              let image = NSImage(data: Data(MermaidSVGFlattener.flatten(svg).utf8)),
              let ink = inkBox(of: image),
              // User units per rendered pixel — 1:1 here (the width attribute
              // matches the viewBox), but not worth assuming.
              image.size.width > 0, image.size.height > 0
        else { return svg }
        let scaleX = width / Double(image.size.width), scaleY = height / Double(image.size.height)
        let box = CGRect(x: x + ink.minX * scaleX, y: y + ink.minY * scaleY,
                         width: ink.width * scaleX, height: ink.height * scaleY)
        guard box.width < width || box.height < height else { return svg }

        // Only the opening tag's own geometry: a diagram's body can carry the
        // same attribute names on its shapes.
        guard let openTag = svg.range(of: #"<svg[^>]*>"#, options: .regularExpression) else { return svg }
        var tag = String(svg[openTag])
        for (attribute, value) in [("viewBox", String(format: "%g %g %g %g",
                                                      box.minX, box.minY, box.width, box.height)),
                                   ("width", String(format: "%g", box.width)),
                                   ("height", String(format: "%g", box.height))] {
            tag = tag.replacingOccurrences(of: "\\s\(attribute)=\"[^\"]*\"",
                                           with: " \(attribute)=\"\(value)\"",
                                           options: .regularExpression)
        }
        return svg.replacingCharacters(in: openTag, with: tag)
    }

    /// Bounding box of everything `image` actually draws, in its own points.
    /// One point of air so an antialiased edge can't be shaved.
    private static func inkBox(of image: NSImage) -> CGRect? {
        let w = Int(image.size.width.rounded()), h = Int(image.size.height.rounded())
        guard w > 0, h > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        guard let pixels = rep.bitmapData else { return nil }

        let rowBytes = rep.bytesPerRow, pixelBytes = rep.bitsPerPixel / 8
        var minX = w, maxX = -1, minY = h, maxY = -1
        for row in 0..<h {
            let base = pixels + row * rowBytes
            for column in 0..<w where base[column * pixelBytes + 3] > 8 {   // alpha
                if column < minX { minX = column }
                if column > maxX { maxX = column }
                if row < minY { minY = row }
                maxY = row
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let left = max(0, minX - 1), top = max(0, minY - 1)
        return CGRect(x: left, y: top,
                      width: min(w, maxX + 2) - left, height: min(h, maxY + 2) - top)
    }

    /// Capture groups of the first match, `[whole, 1, 2, …]`, or nil.
    private static func firstMatch(_ pattern: String, in s: String) -> [String]? {
        let ns = s as NSString
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length))
        else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }

    /// Edit mode's form of the same diagram: the SVG drawn by CoreSVG into a
    /// vector-backed `NSImage`, after `MermaidSVGFlattener` has rewritten the
    /// CSS CoreSVG doesn't understand. `svg()` is the trust boundary and the
    /// parse-failure path; this only reshapes what it approved. Nil for the
    /// same reasons `svg()` is nil, plus one that is a bug rather than user
    /// input: CoreSVG refusing the flattened document, logged as such.
    func image(source: String, style: MermaidStyle) -> NSImage? {
        guard let svg = svg(source: source, style: style) else { return nil }
        let key = svg as NSString
        if let hit = imageCache.object(forKey: key) { return hit }
        guard let decoded = NSImage(data: Data(MermaidSVGFlattener.flatten(svg).utf8)),
              decoded.size.width > 0, decoded.size.height > 0 else {
            Log.error("Mermaid: CoreSVG could not decode a flattened diagram")
            return nil
        }
        imageCache.setObject(decoded, forKey: key)
        return decoded
    }

    /// Read mode's page promises to reach the network for nothing and to run
    /// no script. The payload's shim already strips the webfont `@import`, so
    /// this is the trust boundary that checks it actually did — the SVG is
    /// spliced into the document as live markup, not as an opaque image.
    ///
    /// `url(#…)` is explicitly allowed: same-document fragment references are
    /// how every arrowhead is drawn (nine of them in a five-node flowchart).
    /// Rejecting `url(` outright would silently strip the arrowheads off every
    /// diagram.
    nonisolated static func isSafeSVG(_ svg: String) -> Bool {
        let lowered = svg.lowercased()
        for forbidden in ["<script", "<foreignobject", "<iframe", "javascript:", "@import", "<!entity", "<use"] {
            if lowered.contains(forbidden) { return false }
        }
        // Any url(...) that is not a same-document fragment reference.
        if lowered.range(of: #"url\(\s*(?!#)"#, options: .regularExpression) != nil { return false }
        // on* event-handler attributes (onload=, onclick=, …).
        if lowered.range(of: #"\son[a-z]+\s*="#, options: .regularExpression) != nil { return false }
        return true
    }
}
