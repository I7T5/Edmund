import AppKit

// MARK: - LucideIcons
//
// Vendored [Lucide](https://lucide.dev) icons, used for callout headers and
// Read-mode checkboxes. We vendor the SVG markup (rather than SF Symbols)
// because Read mode / PDF export *redistributes* the rendered icons, and the SF
// Symbols license forbids distributing those symbols in print form. Lucide is
// ISC-licensed (a few icons MIT, via Feather) — both permit redistribution; the
// notices live in `LICENSES/lucide.txt`.
//
// Only each icon's inner geometry is stored; `inlineSVG`/`image` wrap it in a
// 24×24, stroke-based `<svg>` matching Lucide's canonical form. One source feeds
// both back-ends: Read mode inlines the SVG (vector, CSS-tinted via
// `currentColor`); Edit mode rasterizes it to a tinted `NSImage` overlay.
enum LucideIcons {

    /// Lucide icon id → inner SVG geometry, verbatim from lucide.dev (v ISC).
    /// Keys match `CalloutStyle.iconName` plus the checkbox primitives.
    static let geometry: [String: String] = [
        "pencil": #"<path d="M21.174 6.812a1 1 0 0 0-3.986-3.987L3.842 16.174a2 2 0 0 0-.5.83l-1.321 4.352a.5.5 0 0 0 .623.622l4.353-1.32a2 2 0 0 0 .83-.497z"/><path d="m15 5 4 4"/>"#,
        "flame": #"<path d="M12 3q1 4 4 6.5t3 5.5a1 1 0 0 1-14 0 5 5 0 0 1 1-3 1 1 0 0 0 5 0c0-2-1.5-3-1.5-5q0-2 2.5-4"/>"#,
        "message-square-warning": #"<path d="M22 17a2 2 0 0 1-2 2H6.828a2 2 0 0 0-1.414.586l-2.202 2.202A.71.71 0 0 1 2 21.286V5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2z"/><path d="M12 15h.01"/><path d="M12 7v4"/>"#,
        "triangle-alert": #"<path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3"/><path d="M12 9v4"/><path d="M12 17h.01"/>"#,
        "octagon-alert": #"<path d="M12 16h.01"/><path d="M12 8v4"/><path d="M15.312 2a2 2 0 0 1 1.414.586l4.688 4.688A2 2 0 0 1 22 8.688v6.624a2 2 0 0 1-.586 1.414l-4.688 4.688a2 2 0 0 1-1.414.586H8.688a2 2 0 0 1-1.414-.586l-4.688-4.688A2 2 0 0 1 2 15.312V8.688a2 2 0 0 1 .586-1.414l4.688-4.688A2 2 0 0 1 8.688 2z"/>"#,
        "clipboard-list": #"<rect width="8" height="4" x="8" y="2" rx="1" ry="1"/><path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2"/><path d="M12 11h4"/><path d="M12 16h4"/><path d="M8 11h.01"/><path d="M8 16h.01"/>"#,
        "info": #"<circle cx="12" cy="12" r="10"/><path d="M12 16v-4"/><path d="M12 8h.01"/>"#,
        "circle-dashed": #"<path d="M10.1 2.182a10 10 0 0 1 3.8 0"/><path d="M13.9 21.818a10 10 0 0 1-3.8 0"/><path d="M17.609 3.721a10 10 0 0 1 2.69 2.7"/><path d="M2.182 13.9a10 10 0 0 1 0-3.8"/><path d="M20.279 17.609a10 10 0 0 1-2.7 2.69"/><path d="M21.818 10.1a10 10 0 0 1 0 3.8"/><path d="M3.721 6.391a10 10 0 0 1 2.7-2.69"/><path d="M6.391 20.279a10 10 0 0 1-2.69-2.7"/>"#,
        "check": #"<path d="M20 6 9 17l-5-5"/>"#,
        "circle-question-mark": #"<circle cx="12" cy="12" r="10"/><path d="M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3"/><path d="M12 17h.01"/>"#,
        "x": #"<path d="M18 6 6 18"/><path d="m6 6 12 12"/>"#,
        "zap": #"<path d="M4 14a1 1 0 0 1-.78-1.63l9.9-10.2a.5.5 0 0 1 .86.46l-1.92 6.02A1 1 0 0 0 13 10h7a1 1 0 0 1 .78 1.63l-9.9 10.2a.5.5 0 0 1-.86-.46l1.92-6.02A1 1 0 0 0 11 14z"/>"#,
        "bug": #"<path d="M12 20v-9"/><path d="M14 7a4 4 0 0 1 4 4v3a6 6 0 0 1-12 0v-3a4 4 0 0 1 4-4z"/><path d="M14.12 3.88 16 2"/><path d="M21 21a4 4 0 0 0-3.81-4"/><path d="M21 5a4 4 0 0 1-3.55 3.97"/><path d="M22 13h-4"/><path d="M3 21a4 4 0 0 1 3.81-4"/><path d="M3 5a4 4 0 0 0 3.55 3.97"/><path d="M6 13H2"/><path d="m8 2 1.88 1.88"/><path d="M9 7.13V6a3 3 0 1 1 6 0v1.13"/>"#,
        "list": #"<path d="M3 5h.01"/><path d="M3 12h.01"/><path d="M3 19h.01"/><path d="M8 5h13"/><path d="M8 12h13"/><path d="M8 19h13"/>"#,
        "quote": #"<path d="M16 3a2 2 0 0 0-2 2v6a2 2 0 0 0 2 2 1 1 0 0 1 1 1v1a2 2 0 0 1-2 2 1 1 0 0 0-1 1v2a1 1 0 0 0 1 1 6 6 0 0 0 6-6V5a2 2 0 0 0-2-2z"/><path d="M5 3a2 2 0 0 0-2 2v6a2 2 0 0 0 2 2 1 1 0 0 1 1 1v1a2 2 0 0 1-2 2 1 1 0 0 0-1 1v2a1 1 0 0 0 1 1 6 6 0 0 0 6-6V5a2 2 0 0 0-2-2z"/>"#,
        "circle": #"<circle cx="12" cy="12" r="10"/>"#,
        "image-off": #"<line x1="2" x2="22" y1="2" y2="22"/><path d="M10.41 10.41a2 2 0 1 1-2.83-2.83"/><line x1="13.5" x2="6" y1="13.5" y2="21"/><line x1="18" x2="21" y1="12" y2="15"/><path d="M3.59 3.59A1.99 1.99 0 0 0 3 5v14a2 2 0 0 0 2 2h14c.55 0 1.052-.22 1.41-.59"/><path d="M21 15V5a2 2 0 0 0-2-2H9"/>"#,
    ]

    /// Raw `<svg>…</svg>` with `stroke="currentColor"` for inlining into HTML;
    /// the host CSS supplies the color. Returns `nil` for an unknown id.
    static func inlineSVG(_ name: String) -> String? {
        guard let g = geometry[name] else { return nil }
        return strokeSVG(geometry: g, stroke: "currentColor")
    }

    /// An `NSImage` of the icon stroked in `color`, sized to a `pointSize`
    /// square. Renders the SVG (in black) then tints with `.sourceIn` so the
    /// glyph matches `color` exactly regardless of the SVG decoder's color space
    /// — the same technique the PDF icon path used. `sourceIn` (not
    /// `sourceAtop`) matters when `color` is itself translucent (e.g. a dynamic
    /// system color like `.secondaryLabelColor`): `sourceIn`'s result alpha is
    /// `color.alpha * baseGlyphAlpha`, so the tint's own translucency survives;
    /// `sourceAtop` keeps only the base glyph's alpha, silently discarding the
    /// tint's alpha — invisible with the opaque theme colors this was first
    /// used with, but it flattens a translucent tint to solid opaque. `nil` for
    /// an unknown id or if the platform SVG decoder can't build the image.
    static func image(_ name: String, color: NSColor, pointSize: CGFloat) -> NSImage? {
        guard let g = geometry[name],
              let data = strokeSVG(geometry: g, stroke: "#000000").data(using: .utf8),
              let base = NSImage(data: data) else { return nil }
        base.cacheMode = .never   // re-rasterize the SVG at each draw scale (crisp on Retina)
        let box = NSSize(width: pointSize, height: pointSize)
        let image = NSImage(size: box, flipped: false) { rect in
            base.draw(in: rect)
            color.setFill()
            NSGraphicsContext.current?.cgContext.setBlendMode(.sourceIn)
            rect.fill()
            return true
        }
        image.cacheMode = .never
        return image
    }

    /// The icon's stroke geometry as a CGPath in Lucide's canonical 24×24,
    /// y-down viewBox space (stroke it with width 2, round caps/joins, to
    /// match the rendered SVG). Used where the icon must be drawn as a
    /// *shape*, not an image — an image on a wrapping TextKit 2 fragment
    /// wedges its layout to one line (see FragmentOverlay). `nil` for an
    /// unknown id.
    static func path(_ name: String) -> CGPath? {
        guard let g = geometry[name] else { return nil }
        return SVGPath.path(fromGeometry: g)
    }

    /// Read-mode checkbox markup mirroring the editor's look. Unchecked: a
    /// stroked `circle`. Checked: a disc filled in `currentColor` (CSS supplies
    /// the accent) with a white check on top. The themeable part uses
    /// `currentColor`; the check is a literal white so it reads on the disc.
    static func checkboxSVG(checked: Bool) -> String {
        if checked {
            return ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><circle cx="12" cy="12" r="11" fill="currentColor"/><path d="m7.5 12.5 3 3 6-7" fill="none" stroke="#fff" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/></svg>"##
        }
        return #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><circle cx="12" cy="12" r="10" fill="none" stroke="currentColor" stroke-width="2"/></svg>"#
    }

    /// Wraps inner `geometry` in Lucide's canonical stroke-based `<svg>`.
    private static func strokeSVG(geometry: String, stroke: String) -> String {
        #"<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke=""#
            + stroke
            + #"" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">"#
            + geometry
            + "</svg>"
    }
}
