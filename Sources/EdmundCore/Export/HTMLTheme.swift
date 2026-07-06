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
                    dark: Bool,
                    maxContentWidthPoints: Double = .greatestFiniteMagnitude) -> String {
        let bg = dark ? "#1e1e1e" : "#ffffff"
        let fg = dark ? "#e6e6e6" : "#1a1a1a"
        let faint = dark ? "#9a9a9a" : "#6a6a6a"
        let rule = dark ? "#3a3a3a" : "#e0e0e0"
        let codeBg = dark ? "#2a2a2a" : "#f4f4f4"

        // line-height: editor `NSParagraphStyle.lineSpacing` adds extra points
        // *between* lines on top of the font's natural leading (~1.2×). The CSS
        // equivalent is 1.2 + (lineSpacing / fontSize).
        let lineHeight = 1.2 + theme.lineSpacing / theme.fontSize

        // CSS px and AppKit points are both device-independent, so the editor's
        // physical cap (EditorTextView.maxContentWidthPoints) carries over as-is.
        // A huge/infinite value means "uncapped" in the editor too; `none` skips
        // the constraint instead of emitting an unusable giant number.
        let pageMaxWidth = maxContentWidthPoints < 100_000
            ? "\(trim(CGFloat(maxContentWidthPoints)))px" : "none"

        return """
        :root {
          --body-font: \(cssFontStack(theme.fontName, generic: "serif"));
          --body-size: \(trim(theme.fontSize))px;
          --mono-font: \(cssFontStack(theme.monospaceFontName.isEmpty ? "ui-monospace" : theme.monospaceFontName, generic: "monospace"));
          --mono-size: \(trim(theme.monospaceFontSize))px;
          --accent: \(theme.linkBlueHex);
          --code: \(theme.codeHex);
          --bg: \(bg);
          --fg: \(fg);
          --faint: \(faint);
          --rule: \(rule);
          --code-bg: \(codeBg);
          --marker: \(resolvedRGBA(.tertiaryLabelColor, dark: dark));
          --check-fill: \(resolvedRGBA(.controlAccentColor, dark: dark));
          --line-height: \(trim(lineHeight));
          --para-space: \(trim(max(theme.paragraphSpacingBefore, 0)))px;
          --page-max-width: \(pageMaxWidth);
        }
        \(calloutVars(callouts, dark: dark))
        \(staticRules)
        \(codeTokenRules(dark: dark))
        """
    }

    // MARK: Code syntax colors

    /// `.tok-*` color rules for fenced code blocks, from the shared
    /// `CodeSyntaxPalette` so Read mode matches the editor token-for-token. The
    /// `pre code` rule overrides the static `var(--fg)` so plain (un-tokenized)
    /// code uses the palette's plain color too, like the editor.
    private static func codeTokenRules(dark: Bool) -> String {
        func rule(_ selector: String, _ type: CodeHighlighter.TokenType?) -> String {
            "\(selector) { color: \(CodeSyntaxPalette.hex(type, dark: dark)); }"
        }
        return [
            rule("pre code", nil),
            rule("pre code .tok-keyword", .keyword),
            rule("pre code .tok-type", .type),
            rule("pre code .tok-string", .string),
            rule("pre code .tok-number", .number),
            rule("pre code .tok-comment", .comment),
            rule("pre code .tok-function", .function),
        ].joined(separator: "\n")
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
    .page { max-width: var(--page-max-width); margin: 0 auto; }
    /* Styled-source spacing: paragraphs and blocks get a full line's breathing
       room, so the cadence feels like a clean, readable version of Edit mode
       rather than a collapsed publication layout. */
    p { margin: 0 0 1em; }
    h1, h2, h3, h4, h5, h6 { line-height: 1.25; font-weight: 600; margin: 1.4em 0 0.5em; }
    h1 { font-size: 1.9em; } h2 { font-size: 1.55em; } h3 { font-size: 1.3em; }
    h4 { font-size: 1.1em; } h5 { font-size: 1em; } h6 { font-size: 0.9em; color: var(--faint); }
    :is(h1, h2, h3, h4, h5, h6):first-child { margin-top: 0; }
    a { color: var(--accent); text-decoration: underline; }
    code { font-family: var(--mono-font); font-size: 0.92em; color: var(--code);
           background: var(--code-bg); padding: 0.1em 0.35em; border-radius: 4px; }
    pre { background: var(--code-bg); padding: 12px 14px; border-radius: 8px; overflow-x: auto;
          /* tab-size: browsers default to 8; match the common editor convention of 4. */
          tab-size: 4; -moz-tab-size: 4; }
    pre code { color: var(--fg); background: none; padding: 0; font-size: var(--mono-size); }
    blockquote { margin: 1em 0; padding: 0.5em 1em; border-left: 3px solid var(--rule); color: var(--faint); }
    /* Without this, the 1em bottom margin on the last <p> inside a blockquote
       creates asymmetric vertical padding — the blockquote looks heavier at the
       bottom than at the top. Reset it so padding alone controls the spacing. */
    blockquote > p:last-child { margin-bottom: 0; }
    /* A nested blockquote that is the last child of its parent blockquote (or
       callout body) would otherwise leave 1em of extra space below itself inside
       the parent's padding. Collapse it. */
    blockquote > blockquote:last-child,
    .callout-body > blockquote:last-child { margin-bottom: 0; }
    hr { border: none; border-top: 1px solid var(--rule); margin: 1.6em 0; }
    mark { background: rgba(255, 200, 0, 0.3); color: inherit; padding: 0 0.1em; }
    /* Whitelisted inline HTML rendered in Read mode (see HTMLRenderer
       sanitizeInlineHTML). <u>/<mark> use the UA underline / the rule above;
       <kbd> matches the editor's inline-key chrome, <sub>/<sup> get the standard
       line-height-safe reset. */
    kbd { font-family: var(--mono-font); font-size: 0.92em; background: var(--code-bg);
          border: 1px solid var(--rule); border-radius: 4px; padding: 0.05em 0.4em; }
    sub, sup { font-size: 0.75em; line-height: 0; position: relative; vertical-align: baseline; }
    sup { top: -0.5em; }
    sub { bottom: -0.25em; }
    /* Footnotes (see HTMLRenderer.renderFootnotesSection): in-text `[^id]` refs
       are plain (undecorated) superscript links; the bottom-of-page list is a
       smaller, dimmer <ol> below its own <hr>, each entry ending in a backref
       arrow to the in-text marker. */
    sup.footnote-ref a { text-decoration: none; }
    hr.footnotes-sep { margin-bottom: 0.8em; }
    ol.footnotes { font-size: 0.85em; color: var(--faint); }
    ol.footnotes li { margin: 0.4em 0; }
    a.footnote-backref { text-decoration: none; margin-left: 0.2em; font-size: 0.9em; line-height: 1; }
    /* Match the editor's list indentation: level-1 text begins at one marker
       slot past the marker (~2.25em), and each nesting level steps in by one
       slot (~1.25em). Same dot at every level, like Edit mode. */
    /* Only direct children of .page and .callout-body get block margin (1em top
       + bottom) and the wider level-1 indent (2.25em). Nested lists inside list
       items stay at 0 margin — otherwise each level compounds to large gaps. */
    ul, ol { margin: 0; padding-left: 1.25em; }
    .page > ul, .page > ol,
    .callout-body > ul, .callout-body > ol { margin: 1em 0; padding-left: 2.25em; }
    li > ul, li > ol { margin: 0; }
    ul { list-style-type: disc; }
    li { margin: 0.2em 0; }
    li::marker { color: var(--marker); font-size: 0.85em; }
    li > p { margin: 0; }
    /* Task items: float the checkbox into the marker slot so the label and
       wrapped lines sit at the same content edge as bullet/number text. The
       negative margin-left pulls the checkbox into the list's padding area; the
       nested <ul>/<ol> clears the float so it falls below.
       Lucide checkbox (a tinted <svg>, see HTMLRenderer/LucideIcons): unchecked =
       dim outlined circle (--marker, the editor's tertiaryLabelColor); checked =
       disc filled in the system accent (--check-fill, matching the editor's
       controlAccentColor) with a white check baked into the SVG. `currentColor`
       in the SVG inherits from `color` below. */
    li.task { list-style: none; }
    li.task > .task-check {
      /* Sized a bit larger than 1em so the Lucide circle (r=10 in a 24-box, so it
         underfills) reads as big as the editor's checkbox. margin-left is roughly
         -(width + margin-right) so the task TEXT starts at the content edge,
         lining up with sibling bullet/number text; hand-tuned to -1.45em (a hair
         less negative than the -1.5em that formula gives) so the marker centers
         over the bullet/number column at every nesting level.
         margin-top (0.1em) centers the box on the first text line's cap-height
         center — tuned visually for Iowan Old Style at 16pt / line-height 1.45. A
         font-agnostic fix would measure NSFont.ascender at render time and emit an
         inline margin-top. */
      float: left; width: 1.2em; height: 1.2em; line-height: 0;
      margin-top: 0.1em;
      margin-right: 0.3em;
      margin-left: -1.45em;
    }
    li.task > .task-check svg { display: block; width: 1.2em; height: 1.2em; }
    .task-check--unchecked { color: var(--marker); }
    .task-check--checked { color: var(--check-fill); }
    li.task--checked > p { opacity: 0.45; text-decoration: line-through; }
    li.task > p { display: inline; margin: 0; }
    li.task > ul, li.task > ol { clear: left; }
    /* Contain the checkbox float within its own item. Without this, a task item
       that has no nested list (the float is never cleared by a child ul/ol)
       leaks its float onto the FOLLOWING sibling, shoving that item's bullet/
       number marker to the right — so sibling markers stop lining up. */
    li.task::after { content: ""; display: block; clear: both; }
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
    /* Outer margin matches the gap between two consecutive <pre> blocks (UA
       stylesheet gives pre { margin: 1em 0 }; collapsing → 1em gap). Using
       the same value here means neighboring callouts look equally spaced. */
    .callout { background: var(--c-bg); border-radius: 8px; padding: 10px 14px; margin: 1em 0; }
    /* Icon sits at the top so it stays on the first line of a wrapped title; its
       box is exactly one line tall and centers the glyph, so it lines up with the
       first line's text rather than floating above it. */
    .callout-title { display: flex; align-items: flex-start; gap: 0.3em;
                     font-weight: 600; color: var(--c-accent); }
    .callout-icon { flex: 0 0 auto; display: inline-flex; align-items: center; justify-content: center;
                    height: calc(var(--body-size) * var(--line-height)); }
    /* Lucide glyphs sit a touch low against the title's optical (cap-height)
       center; nudge the icon up so it reads as centered with the title text. */
    .callout-icon svg { width: 1em; height: 1em; transform: translateY(-0.06em); }
    /* Per-glyph optical nudge: a few Lucide icons sit high in their 24-box, so
       push them down a hair to read as centered against the title cap-height.
       Aliases share an icon, so they get the same value. */
    .callout-info .callout-icon, .callout-todo .callout-icon,
    .callout-question .callout-icon, .callout-help .callout-icon, .callout-faq .callout-icon,
    .callout-quote .callout-icon, .callout-cite .callout-icon { padding-top: 0.05em; }
    .callout-warning .callout-icon, .callout-attention .callout-icon,
    .callout-bug .callout-icon { padding-top: 0.06em; }
    .callout-example .callout-icon { padding-top: 0.1em; }
    .callout-success .callout-icon, .callout-check .callout-icon, .callout-done .callout-icon,
    .callout-failure .callout-icon, .callout-fail .callout-icon,
    .callout-missing .callout-icon { padding-top: 0.15em; }
    .callout-title-text { flex: 1 1 auto; }
    .callout-body { margin-top: 0.4em; }
    /* A title-only callout still emits an empty body div; collapse its top margin
       so the box doesn't carry the 0.4em title gap as dead space at the bottom. */
    .callout-body:empty { margin-top: 0; }
    /* Reduce paragraph spacing inside callout bodies so nested callouts and
       body text don't sit too far apart. The full 1em bottom margin (from the
       global <p> rule) + the nested callout's 0.5em top margin would give
       1.5em gap — halving the paragraph bottom margin brings it to ~1em. */
    .callout-body > p { margin-bottom: 0.5em; }
    .callout-body > :first-child { margin-top: 0; }
    .callout-body > :last-child { margin-bottom: 0; }
    /* A callout that is the last child of a callout body (e.g. the nested TIP
       inside the NOTE) has its top margin removed so the space above it is
       governed only by the preceding element's bottom margin (0.5em for a <p>
       from .callout-body > p), not the combined margin collapse of 1em. */
    .callout-body > .callout:last-child { margin-top: 0; }

    @media print {
      body { padding: 0; }
      /* QUIRK: WebKit strips background colors when printing by default (it
         follows the user's browser setting), even though WKWebView.createPDF
         keeps them. `print-color-adjust: exact` forces faithful color output
         so callout backgrounds, code blocks, and highlights survive printing. */
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
    ///
    /// QUIRK: dynamic system colors like `tertiaryLabelColor` store a catalog
    /// reference, not actual RGBA components — calling `usingColorSpace(.sRGB)`
    /// on one outside a drawing context resolves to nil or returns the wrong
    /// variant. `performAsCurrentDrawingAppearance` sets the appearance context
    /// so the catalog resolves to the correct light or dark concrete color.
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
