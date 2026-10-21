import AppKit

// MARK: - QuickLookPage
//
// What the Quick Look extensions hand to Quick Look.
//
// - The preview: the same self-contained document HTML export builds (math,
//   images and diagrams inlined as data URIs, so Quick Look's renderer needs no
//   file access), in the `.quickLook` theme with a few adjustments for a preview
//   pane.
// - The thumbnail, which Finder's preview column and large icons show (the
//   column never displays a data-based preview live): the RTF export's page
//   through AppKit's HTML importer, drawn onto a white portrait page. No web
//   view, so it renders off-window. TextKit 1 is fine here: the TextKit 2 rule
//   is about the editor's storage (see `RichTextExport`), and the importer's
//   `NSTextTable` blocks only draw through `NSLayoutManager`.
@MainActor
public enum QuickLookPage {

    /// Read mode's margins are sized for a window; the system text preview
    /// insets about 7pt, and 48px wastes most of Finder's preview column.
    /// Bullets: Read mode's 0.85em marker is tuned for Iowan; in the system font
    /// it sits 1px below the x-height middle at 13pt, and 1em puts it 1px above,
    /// as Iowan's does (measured from WebKit renders).
    static let css = """
        body { padding: 12px 14px; }
        ul > li::marker { font-size: 1em; }
        """

    public static func html(markdown: String, baseURL: URL?, dark: Bool) -> String {
        DocumentHTML.full(markdown: markdown, theme: .quickLook,
                          callouts: Callout.defaultStyles, dark: dark,
                          baseURL: baseURL, options: ReadRenderOptions(),
                          extraCSS: css)
    }

    /// The page a thumbnail draws, in points: US Letter's 8.5:11 ratio, but
    /// narrower than Letter's 612pt so 13pt text stays legible scaled down.
    public static let thumbnailPageSize = CGSize(width: 400, height: 400 * 11 / 8.5)
    static let thumbnailMargin: CGFloat = 28

    /// The document's first page as a light, paper-like image of `pixelSize`
    /// (document thumbnails read as paper in both appearances). Nil when the
    /// page can't be imported, so Quick Look falls back to the generic icon.
    public static func thumbnail(markdown: String, baseURL: URL?, pixelSize: CGSize) -> CGImage? {
        let html = RichTextExport.html(markdown: markdown, theme: .quickLook,
                                       callouts: Callout.defaultStyles,
                                       baseURL: baseURL, options: ReadRenderOptions())
        let width = Int(pixelSize.width.rounded()), height = Int(pixelSize.height.rounded())
        guard width > 0, height > 0,
              let text = try? RichTextExport.attributedString(fromHTML: html),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let page = thumbnailPageSize, margin = thumbnailMargin
        let scale = min(CGFloat(width) / page.width, CGFloat(height) / page.height)
        // AppKit text draws top-down: flip, then scale the virtual page to fit.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)

        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: page.width - 2 * margin,
                                                     height: page.height - 2 * margin))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        // Only what fits the page: a finite container stops layout there.
        let glyphs = layout.glyphRange(for: container)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        let origin = CGPoint(x: margin, y: margin)
        layout.drawBackground(forGlyphRange: glyphs, at: origin)
        layout.drawGlyphs(forGlyphRange: glyphs, at: origin)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}
