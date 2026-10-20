import Foundation

// MARK: - QuickLookPage
//
// The page the Quick Look extension hands to Quick Look: the same
// self-contained document HTML export builds (math, images and diagrams
// inlined as data URIs, so Quick Look's renderer needs no file access), in the
// `.quickLook` theme with a few adjustments for a preview pane.
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
}
