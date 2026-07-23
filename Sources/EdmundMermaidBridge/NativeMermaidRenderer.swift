import AppKit
internal import BeautifulMermaid

/// Edmund-facing theme value that keeps BeautifulMermaid's public AppKit
/// extensions behind this target's module boundary.
public struct NativeMermaidTheme: @unchecked Sendable {
    fileprivate let background: NSColor
    fileprivate let foreground: NSColor
    fileprivate let accent: NSColor
    fileprivate let font: NSFont

    public init(background: NSColor,
                foreground: NSColor,
                accent: NSColor,
                font: NSFont) {
        self.background = background
        self.foreground = foreground
        self.accent = accent
        self.font = font
    }

    fileprivate var diagramTheme: DiagramTheme {
        DiagramTheme(background: background, foreground: foreground,
                     accent: accent, font: font)
    }
}

/// Serialized native rendering. BeautifulMermaid shares one ELK instance, so
/// bitmap work and SVG work must not enter it concurrently.
public enum NativeMermaidRenderer {
    private static let lock = NSLock()

    public static func image(source: String,
                             theme: NativeMermaidTheme) throws -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let image = try MermaidRenderer.renderImage(
            source: source, theme: theme.diagramTheme, scale: 2)
        else { return nil }
        // BeautifulMermaid's AppKit bitmap currently has top-down diagram
        // coordinates in a bottom-up CGContext, so its pixels arrive vertically
        // inverted. Correct the pixel orientation once at the bridge boundary;
        // keeping the package's direct bitmap also preserves its resolved theme
        // colors (AppKit's SVG decoder does not resolve the emitted CSS vars).
        return verticallyFlipped(image)
    }

    public static func svg(source: String,
                           theme: NativeMermaidTheme) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        let diagramTheme = theme.diagramTheme
        let options = RenderOptions(
            bg: diagramTheme.background.hexString,
            fg: diagramTheme.foreground.hexString,
            line: diagramTheme.effectiveLine().hexString,
            accent: diagramTheme.effectiveAccent().hexString,
            muted: diagramTheme.effectiveMuted().hexString,
            surface: diagramTheme.effectiveSurface().hexString,
            border: diagramTheme.effectiveBorder().hexString,
            font: theme.font.fontName,
            transparent: false
        )
        // BeautifulMermaid 1.0.4's convenience SVG path tries to flatten
        // nested CSS fallbacks and can produce invalid paint values such as
        // `#F8F8F8 3%, #FFFFFF))`. WKWebView supports the renderer's original
        // SVG variables, so retain that valid vector output at our boundary.
        return try renderMermaidSVG(source, options)
    }

    private static func verticallyFlipped(_ image: NSImage) -> NSImage? {
        guard let source = image.cgImage(
            forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = source.width
        let height = source.height
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
              ) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(source, in: CGRect(x: 0, y: 0,
                                       width: width, height: height))
        guard let corrected = context.makeImage() else { return nil }
        return NSImage(cgImage: corrected, size: image.size)
    }
}
