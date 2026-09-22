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
        cache.setObject(result as NSString, forKey: key)
        return result
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
        let image = Self.trimmingTransparentMargin(decoded)
        imageCache.setObject(image, forKey: key)
        return image
    }

    /// Crops the library's own page margin off a decoded diagram.
    ///
    /// beautiful-mermaid pads its canvas — 29 to 53 pt depending on the diagram
    /// type and the side — which Read mode wants (the SVG is a block in a web
    /// page) and Edit mode does not: there it lands as a slab of dead space
    /// above and below the picture, and holds the drawing off the text's left
    /// edge. The padding is *measured*, not assumed: it differs per side and
    /// per diagram type, so a constant would clip one of them.
    ///
    /// CoreSVG ignores the SVG's CSS `background`, so the margin is genuinely
    /// transparent and the alpha channel is the whole test. The crop is
    /// re-drawn through a handler rather than captured as a bitmap, so the
    /// result stays resolution-independent.
    private static func trimmingTransparentMargin(_ image: NSImage) -> NSImage {
        let w = Int(image.size.width.rounded()), h = Int(image.size.height.rounded())
        guard w > 0, h > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        guard let pixels = rep.bitmapData else { return image }

        let rowBytes = rep.bytesPerRow, pixelBytes = rep.bitsPerPixel / 8
        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h {
            let row = pixels + y * rowBytes
            for x in 0..<w where row[x * pixelBytes + 3] > 8 {   // alpha, ignoring near-nothing
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                maxY = y
            }
        }
        guard maxX >= minX, maxY >= minY else { return image }   // nothing drawn: leave it alone

        // One point of air so an antialiased edge can't be shaved.
        let box = CGRect(x: max(0, minX - 1), y: max(0, minY - 1),
                         width: min(w, maxX + 2) - max(0, minX - 1),
                         height: min(h, maxY + 2) - max(0, minY - 1))
        guard box.width < image.size.width || box.height < image.size.height else { return image }

        // The raster's y runs top-down; NSImage's drawing space is bottom-up.
        let bottomInset = image.size.height - box.maxY
        let cropped = NSImage(size: box.size, flipped: false) { rect in
            image.draw(in: CGRect(x: rect.minX - box.minX, y: rect.minY - bottomInset,
                                  width: image.size.width, height: image.size.height))
            return true
        }
        cropped.cacheMode = .never   // re-rasterize at the screen's scale, like other overlays
        return cropped
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
