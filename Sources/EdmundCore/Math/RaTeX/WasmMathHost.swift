import AppKit
import JavaScriptCore

/// Hosts RaTeX's `ratex-wasm` in a `JSContext` and renders LaTeX by asking the
/// module for a display list, then rasterizing it ourselves
/// (`RaTeXDisplayListRenderer`). JavaScriptCore supports the `WebAssembly` API
/// on macOS; the wasm-bindgen glue needs a couple of shims JSCore lacks
/// (`TextEncoder`/`TextDecoder`) and is an ES module we flatten to plain
/// globals so `initSync(bytes)` can byte-init it with no `fetch`.
///
/// Install directory layout (produced by `RaTeXInstaller`):
///   `ratex_wasm_bg.wasm`, `ratex_wasm.js`, `fonts/KaTeX_*.ttf`
///
/// Confined to the main actor: the only callers (`mathOverlay`,
/// `DocumentHTML`) are already main-actor, and it touches `NSImage`/CoreText.
@MainActor
public final class WasmMathHost {
    private var ctx: JSContext?
    public private(set) var isLoaded = false
    private var renderer: RaTeXDisplayListRenderer?
    private var fontCache: [String: CGFont] = [:]

    private final class Cached { let m: RenderedMath; init(_ m: RenderedMath) { self.m = m } }
    private let cache = NSCache<NSString, Cached>()

    /// Minimal UTF-8 `TextEncoder`/`TextDecoder`, which JavaScriptCore doesn't
    /// provide but wasm-bindgen's string marshalling needs.
    private static let polyfills = """
    globalThis.TextEncoder = class { encode(s){ s = unescape(encodeURIComponent(s)); const a = new Uint8Array(s.length); for(let i=0;i<s.length;i++) a[i]=s.charCodeAt(i); return a; } };
    globalThis.TextDecoder = class { decode(buf){ if(!buf) return ''; const u = buf instanceof Uint8Array ? buf : new Uint8Array(buf); let s=''; for(let i=0;i<u.length;i++) s+=String.fromCharCode(u[i]); return decodeURIComponent(escape(s)); } };
    """

    public init() {}

    /// Loads the wasm + glue from `dir` and wires the display-list renderer to
    /// `dir/fonts`. Sets `isLoaded` on success; leaves it false on any failure
    /// (missing files, JS error) so `MathRendering` falls back to SwiftMath —
    /// a load failure must never crash the app.
    public func load(dir: URL) {
        guard var glue = try? String(contentsOf: dir.appendingPathComponent("ratex_wasm.js"), encoding: .utf8),
              let wasm = try? Data(contentsOf: dir.appendingPathComponent("ratex_wasm_bg.wasm")) else {
            return
        }
        let context = JSContext()!
        context.exceptionHandler = { _, exc in
            Log.error("RaTeX JS error: \(exc?.toString() ?? "?")", category: .render)
        }
        context.evaluateScript(Self.polyfills)

        // Flatten the wasm-bindgen ES module to plain globals: drop `export`,
        // the trailing `export {…}` line, and neutralize the `import.meta.url`
        // token (only used by the async fetch init we never call).
        glue = glue.replacingOccurrences(of: "export function", with: "function")
        glue = glue.replacingOccurrences(of: "export { initSync, __wbg_init as default };", with: "")
        glue = glue.replacingOccurrences(of: "export default", with: "var __edmundIgnored =")
        glue = glue.replacingOccurrences(of: "import.meta.url", with: "''")
        context.evaluateScript(glue)

        context.setObject(wasm.map { NSNumber(value: $0) }, forKeyedSubscript: "__ratexWasmBytes" as NSString)
        context.evaluateScript("""
        try {
            globalThis.__ratexU8 = new Uint8Array(__ratexWasmBytes);
            initSync({ module: __ratexU8 });
            globalThis.__ratexReady = (typeof renderLatex === 'function');
        } catch (e) { globalThis.__ratexReady = false; globalThis.__ratexInitErr = String(e); }
        """)
        guard context.objectForKeyedSubscript("__ratexReady")?.toBool() == true else {
            let err = context.objectForKeyedSubscript("__ratexInitErr")?.toString() ?? "unknown"
            Log.error("RaTeX wasm init failed: \(err)", category: .render)
            return
        }

        let fontsDir = dir.appendingPathComponent("fonts", isDirectory: true)
        self.ctx = context
        self.renderer = RaTeXDisplayListRenderer(fontLoader: { [weak self] name in
            self?.cgFont(named: name, in: fontsDir)
        })
        self.isLoaded = true
    }

    /// Clears the loaded module (e.g. after uninstall). Cheap — the JSContext
    /// and caches are dropped; nothing else to tear down.
    public func unload() {
        ctx = nil
        renderer = nil
        fontCache.removeAll()
        cache.removeAllObjects()
        isLoaded = false
    }

    public func render(latex: String, displayMode: Bool,
                       pointSize: CGFloat, color: NSColor) -> RenderedMath? {
        guard isLoaded, let ctx, let renderer else { return nil }

        let dev = (color.usingColorSpace(.deviceRGB) ?? color)
        let key = "\(displayMode ? "D" : "I")|\(String(format: "%.1f", pointSize))|" +
                  "\(String(format: "%.3f,%.3f,%.3f,%.3f", dev.redComponent, dev.greenComponent, dev.blueComponent, dev.alphaComponent))|" +
                  latex as NSString
        if let hit = cache.object(forKey: key) { return hit.m }

        // `renderLatex(latex, color, displayMode)` — the third argument arrived
        // in RaTeX 0.1.14 and is what actually selects block vs inline
        // typesetting. It must be passed explicitly: it *defaults to true*, so
        // the earlier two-argument call rendered inline `$…$` math in display
        // style (`\sum`'s limits stacked above/below instead of beside it).
        // Prefixing `\displaystyle` was never the lever it looked like — with
        // the default already display, it measured identically with and
        // without, so it's gone. The per-item color in the JSON is ignored —
        // the renderer tints to `color`, so the cache stays color-keyed.
        guard let fn = ctx.objectForKeyedSubscript("renderLatex"),
              let result = fn.call(withArguments: [latex, "#000000", displayMode]),
              !result.isUndefined, !result.isNull,
              let json = result.toString() else { return nil }

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let rendered = renderer.render(json: json, pointSize: pointSize, color: color, scale: scale) else {
            return nil   // decode failure = RaTeX couldn't parse it → per-equation fallback
        }
        cache.setObject(Cached(rendered), forKey: key)
        return rendered
    }

    private func cgFont(named ratexName: String, in fontsDir: URL) -> CGFont? {
        if let f = fontCache[ratexName] { return f }
        let url = fontsDir.appendingPathComponent("KaTeX_\(ratexName).ttf")
        guard let data = try? Data(contentsOf: url),
              let provider = CGDataProvider(data: data as CFData),
              let font = CGFont(provider) else {
            Log.error("RaTeX missing font KaTeX_\(ratexName).ttf", category: .render)
            return nil
        }
        fontCache[ratexName] = font
        return font
    }
}
