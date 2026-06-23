import AppKit

// MARK: - HTMLTheme
//
// Emits the CSS for Read mode / PDF export from the *same* `EditorTheme` and
// `CalloutStyle` models the editor renders from, so the two can't drift. The
// theme is the single source of truth for the values it carries (body font/size,
// accent, code color, line/paragraph spacing, callout colors); spacing for
// elements the theme doesn't model (headings, list indent) uses tasteful
// document defaults.
//
// Colors are resolved for one appearance (`dark`); the Read view re-renders when
// the system appearance flips.
enum HTMLTheme {

    @MainActor
    static func css(_ theme: EditorTheme,
                    callouts: [String: CalloutStyle],
                    dark: Bool) -> String {
        let bg = dark ? "#1e1e1e" : "#ffffff"
        let fg = dark ? "#e6e6e6" : "#1a1a1a"
        let faint = dark ? "#9a9a9a" : "#6a6a6a"
        let rule = dark ? "#3a3a3a" : "#e0e0e0"
        let codeBg = dark ? "#2a2a2a" : "#f4f4f4"

        // line-height: editor `NSParagraphStyle.lineSpacing` adds extra points
        // *between* lines on top of the font's natural leading (~1.2×). The CSS
        // equivalent is 1.2 + (lineSpacing / fontSize).
        let lineHeight = 1.2 + theme.lineSpacing / theme.fontSize

        return """
        :root {
          --body-font: \(cssFontStack(theme.fontName, generic: "serif"));
          --body-size: \(trim(theme.fontSize))px;
          --mono-font: \(cssFontStack(theme.monospaceFontName.isEmpty ? "ui-monospace" : theme.monospaceFontName, generic: "monospace"));
          --mono-size: \(trim(theme.monospaceFontSize))px;
          --accent: \(theme.accentHex);
          --code: \(theme.codeHex);
          --bg: \(bg);
          --fg: \(fg);
          --faint: \(faint);
          --rule: \(rule);
          --code-bg: \(codeBg);
          --marker: \(resolvedRGBA(.tertiaryLabelColor, dark: dark));
          --line-height: \(trim(lineHeight));
          --para-space: \(trim(max(theme.paragraphSpacingBefore, 0)))px;
        }
        \(calloutVars(callouts, dark: dark))
        \(staticRules)
        """
    }

    // MARK: Callout custom properties

    @MainActor
    private static func calloutVars(_ callouts: [String: CalloutStyle], dark: Bool) -> String {
        // De-dup styles shared by aliases: emit one rule block per type key.
        var out = ""
        for type in callouts.keys.sorted() {
            let style = callouts[type]!
            let accent = style.accentHex(dark: dark)
            let border = style.resolvedBorderHex(dark: dark)
            let bg = style.explicitBackgroundHex(dark: dark)
                ?? rgba(accent, alpha: style.backgroundAlpha)
            out += """
            .callout-\(type) {
              --c-accent: \(accent);
              --c-border: \(border);
              --c-bg: \(bg);
              --c-border-width: \(trim(style.borderWidth))px;
              \(borderEdgeRules(style.borderEdges))
            }

            """
        }
        return out
    }

    private static func borderEdgeRules(_ edges: CalloutStyle.Edges) -> String {
        var parts: [String] = []
        if edges.contains(.left)   { parts.append("border-left: var(--c-border-width) solid var(--c-border);") }
        if edges.contains(.top)    { parts.append("border-top: var(--c-border-width) solid var(--c-border);") }
        if edges.contains(.right)  { parts.append("border-right: var(--c-border-width) solid var(--c-border);") }
        if edges.contains(.bottom) { parts.append("border-bottom: var(--c-border-width) solid var(--c-border);") }
        return parts.joined(separator: " ")
    }

    // MARK: Static element rules

    private static let staticRules = """
    * { box-sizing: border-box; }
    html { -webkit-text-size-adjust: 100%; }
    body {
      font-family: var(--body-font);
      font-size: var(--body-size);
      line-height: var(--line-height);
      color: var(--fg);
      background: var(--bg);
      margin: 0;
      padding: 48px 24px;
    }
    .page { max-width: 46em; margin: 0 auto; }
    p { margin: 0 0 var(--para-space); }
    h1, h2, h3, h4, h5, h6 { line-height: 1.25; font-weight: 600; margin: 1.4em 0 0.5em; }
    h1 { font-size: 1.9em; } h2 { font-size: 1.55em; } h3 { font-size: 1.3em; }
    h4 { font-size: 1.1em; } h5 { font-size: 1em; } h6 { font-size: 0.9em; color: var(--faint); }
    :is(h1, h2, h3, h4, h5, h6):first-child { margin-top: 0; }
    a { color: var(--accent); text-decoration: underline; }
    code { font-family: var(--mono-font); font-size: 0.92em; color: var(--code);
           background: var(--code-bg); padding: 0.1em 0.35em; border-radius: 4px; }
    pre { background: var(--code-bg); padding: 12px 14px; border-radius: 8px; overflow-x: auto; }
    pre code { color: var(--fg); background: none; padding: 0; font-size: var(--mono-size); }
    blockquote { margin: 1em 0; padding: 0.2em 1em; border-left: 3px solid var(--rule); color: var(--faint); }
    hr { border: none; border-top: 1px solid var(--rule); margin: 1.6em 0; }
    mark { background: rgba(255, 200, 0, 0.3); color: inherit; padding: 0 0.1em; }
    /* Match the editor's list indentation: level-1 text begins at one marker
       slot past the marker (~2.25em), and each nesting level steps in by one
       slot (~1.25em). Same dot at every level, like Edit mode. */
    ul, ol { margin: 0 0 var(--para-space); padding-left: 1.25em; }
    .page > ul, .page > ol { padding-left: 2.25em; }
    ul { list-style-type: disc; }
    li { margin: 0.15em 0; }
    li::marker { color: var(--marker); font-size: 0.85em; }
    li > p { margin: 0; }
    /* Task items align with bullet/number lists: the checkbox is floated into
       the marker slot (negative margin) rather than adding indent, so the label
       and wrapped lines sit at the same content edge as a bullet's text — and
       wrapped lines never tuck under the checkbox. */
    li.task { list-style: none; }
    li.task > input[type=checkbox] {
      float: left; width: 1em; height: 1em; margin: 0.25em 0.4em 0 -1.4em;
    }
    li.task > p { display: inline; margin: 0; }
    li.task > ul, li.task > ol { clear: left; }
    .blank-line { height: calc(var(--body-size) * var(--line-height)); }
    table { border-collapse: collapse; margin: 1em 0; width: 100%; }
    th, td { border: 1px solid var(--rule); padding: 6px 10px; }
    thead th { background: var(--code-bg); }
    img { max-width: 100%; }
    img.math { vertical-align: middle; }
    .math-display { text-align: center; margin: 1em 0; }

    /* Callouts: tinted box + colored title; the icon sits as a non-shrinking
       flex child so a long custom title wraps under the title text, never under
       the icon — the layout the TextKit editor can't achieve. */
    .callout { background: var(--c-bg); border-radius: 8px; padding: 10px 14px; margin: 0.5em 0; }
    /* Icon sits at the top so it stays on the first line of a wrapped title; its
       box is exactly one line tall and centers the glyph, so it lines up with the
       first line's text rather than floating above it. */
    .callout-title { display: flex; align-items: flex-start; gap: 0.5em;
                     font-weight: 600; color: var(--c-accent); }
    .callout-icon { flex: 0 0 auto; display: inline-flex; align-items: center; justify-content: center;
                    height: calc(var(--body-size) * var(--line-height)); }
    .callout-icon img { width: 1em; height: 1em; }
    .callout-title-text { flex: 1 1 auto; }
    .callout-body { margin-top: 0.4em; }
    .callout-body > :first-child { margin-top: 0; }
    .callout-body > :last-child { margin-bottom: 0; }

    @media print {
      body { padding: 0; }
      /* Force WebKit to keep background colors (highlight, code, callouts) when
         printing — it strips them by default, unlike createPDF. */
      * { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
      .callout, pre, blockquote, table, .math-display { break-inside: avoid; }
      h1, h2, h3, h4, h5, h6 { break-after: avoid; }
      thead { display: table-header-group; }
    }
    """

    // MARK: Helpers

    /// A CSS font stack: the (possibly multi-word) macOS family name quoted, then
    /// a system fallback and a generic. WKWebView resolves installed families
    /// (e.g. "Iowan Old Style") by name; the generic guards the rest.
    private static func cssFontStack(_ family: String, generic: String) -> String {
        let trimmed = family.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "ui-monospace" {
            return "ui-monospace, \(generic)"
        }
        return "\"\(trimmed)\", -apple-system, \(generic)"
    }

    /// Resolves a (possibly dynamic/catalog) `NSColor` for the given appearance
    /// to a CSS `rgba(...)`, preserving alpha. Used so list markers use the exact
    /// same dim as the editor (`NSColor.tertiaryLabelColor`) and can't drift.
    @MainActor
    private static func resolvedRGBA(_ color: NSColor, dark: Bool) -> String {
        var resolved = color
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        guard let c = resolved.usingColorSpace(.sRGB) else {
            return dark ? "rgba(235,235,245,0.25)" : "rgba(60,60,67,0.3)"
        }
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return "rgba(\(r), \(g), \(b), \(trim(c.alphaComponent)))"
    }

    /// rgba(...) from a "#RRGGBB" hex and an alpha.
    private static func rgba(_ hex: String, alpha: CGFloat) -> String {
        guard let (r, g, b) = rgbComponents(hex) else { return hex }
        return "rgba(\(r), \(g), \(b), \(trim(alpha)))"
    }

    private static func rgbComponents(_ hex: String) -> (Int, Int, Int)? {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let rgb = UInt64(h, radix: 16) else { return nil }
        return (Int((rgb >> 16) & 0xFF), Int((rgb >> 8) & 0xFF), Int(rgb & 0xFF))
    }

    /// Formats a CGFloat without a trailing ".0" so CSS reads cleanly.
    private static func trim(_ v: CGFloat) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%g", v)
    }
}
