import Foundation
import Markdown

// MARK: - HTMLRenderer
//
// Renders the *same* swift-markdown `Document` the editor parses into an HTML
// body string. This is the Read-mode / Print-export counterpart to
// `SpanCollector` (which produces editor attribute spans): one parser, one set
// of element semantics, two back-ends. It mirrors SpanCollector's element
// coverage so Read mode shows exactly what Edit mode highlights.
//
// The renderer is intentionally **pure** — AST → string, no AppKit. Assets that
// need AppKit (callout icons, math glyphs) are emitted as placeholder elements
// that `DocumentHTML` fills in a second pass, so this type stays unit-testable
// with plain string assertions.
//
// Non-GFM inline constructs (==highlight==, $math$, [[wikilink]], %%comment%%)
// are detected by reusing the exact regex passes in
// `SyntaxHighlighter+CustomParsers` — no second source of truth.
struct HTMLRenderer: MarkupVisitor {
    typealias Result = String

    /// Private URL scheme for `[[wikilink]]` hrefs. The read view's navigation
    /// policy intercepts this scheme and routes the (percent-decoded) target
    /// through the app's document graph instead of navigating the webview.
    static let wikiScheme = "x-edmund-wiki"

    /// Private URL scheme for relative/internal regular markdown links
    /// (`[text](other.md)`). Routed like wikilinks; external links (http/https/
    /// mailto) and in-page `#fragment` anchors keep their real hrefs.
    static let linkScheme = "x-edmund-link"

    /// Private URL scheme for a code block's copy button — the base64-encoded
    /// code is the whole payload (survives URL encoding untouched; the code
    /// can contain `#`, `%`, embedded newlines, anything). Intercepted the
    /// same way as the schemes above, and never actually navigated to.
    static let copyScheme = "x-edmund-copy"

    /// The markdown this instance is rendering. Held so block-level constructs
    /// (callouts) can recover their *raw* source text by range, the way the
    /// editor's styling layer does.
    private let source: String
    private let sourceLines: [String]
    private let options: ReadRenderOptions

    /// Footnote definitions collected while walking the document (see
    /// `visitParagraph`), rendered as a section at the bottom of the page
    /// instead of in place. Order is document order of the *definitions*.
    private var footnotes: [(id: String, bodyHTML: String)] = []

    /// Tightness of each list currently being walked (stack: nested lists).
    /// See `isTight(_:)`.
    private var listIsTight: [Bool] = []

    private init(source: String, options: ReadRenderOptions) {
        self.source = source
        self.sourceLines = source.components(separatedBy: "\n")
        self.options = options
    }

    /// Parses `markdown` and returns the rendered HTML body (no `<html>`/`<head>`
    /// wrapper — `DocumentHTML` adds that).
    static func render(markdown: String, options: ReadRenderOptions = .default) -> String {
        // Strip block constructs swift-markdown can't hide for us before it
        // parses (front matter, block-spanning `%%…%%`). `source` and `doc`
        // must see the same text so range-based raw-text recovery stays aligned.
        let prepared = preprocess(markdown, options: options)
        var r = HTMLRenderer(source: prepared, options: options)
        let doc = Document(parsing: prepared, options: [.disableSmartOpts])
        let body = r.visit(doc)
        return body + r.renderFootnotesSection()
    }

    /// Removes constructs that must be gone before swift-markdown parses:
    /// leading YAML front matter (hidden in Read) and block-spanning `%%…%%`
    /// comments (swift-markdown splits them at blank lines, so the per-node
    /// inline `.comment` pass can't catch them). Each gated by its flag.
    private static func preprocess(_ markdown: String, options: ReadRenderOptions) -> String {
        var s = markdown
        if options.features.contains(.frontMatter) { s = stripFrontMatter(s) }
        if options.features.contains(.multiBlockComment) { s = stripMultiBlockComments(s) }
        return s
    }

    /// Drops a leading `---`…`---` YAML block (and one following blank line).
    /// No leading `---`, or no closing `---`, ⇒ unchanged.
    private static func stripFrontMatter(_ md: String) -> String {
        let lines = md.components(separatedBy: "\n")
        guard let first = lines.first,
              first.trimmingCharacters(in: .whitespaces) == "---" else { return md }
        for k in 1..<lines.count where lines[k].trimmingCharacters(in: .whitespaces) == "---" {
            var rest = Array(lines[(k + 1)...])
            if rest.first == "" { rest.removeFirst() }   // one blank separator
            return rest.joined(separator: "\n")
        }
        return md   // unclosed: not front matter
    }

    private static let multiBlockCommentRegex =
        try! NSRegularExpression(pattern: "%%[\\s\\S]*?%%")

    /// Removes `%%…%%` comments that span lines (the block-level case). A
    /// single-line `%%x%%` is left to the inline `.comment` pass.
    private static func stripMultiBlockComments(_ md: String) -> String {
        let ns = md as NSString
        let matches = multiBlockCommentRegex.matches(
            in: md, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return md }
        let result = NSMutableString(string: md)
        // Replace from the end so earlier match ranges stay valid.
        for m in matches.reversed() where ns.substring(with: m.range).contains("\n") {
            result.replaceCharacters(in: m.range, with: "")
        }
        return result as String
    }

    /// `[^id]: body` definitions render at the bottom of the page as a `<hr>` +
    /// ordered list, each entry linking back to its in-text reference — the
    /// Obsidian-style footnote layout (see misc/backlog.md's Markdown Footnotes
    /// entry). Not rendered at all if the document had no footnote definitions.
    private func renderFootnotesSection() -> String {
        guard !footnotes.isEmpty else { return "" }
        var out = "<hr class=\"footnotes-sep\"><ol class=\"footnotes\">"
        for (id, bodyHTML) in footnotes {
            let safeID = Self.attr(id)
            out += "<li id=\"fn-\(safeID)\">\(bodyHTML) " +
                   "<a href=\"#fnref-\(safeID)\" class=\"footnote-backref\">↩</a></li>"
        }
        out += "</ol>"
        return out
    }

    /// Top-level block iteration. When `preserveBlankLines` is on, a *run* of
    /// blank source lines between two blocks emits one `.blank-line` spacer for
    /// every blank line beyond the first — i.e. standard Markdown keeps a single
    /// blank line as the normal block separator and only renders the 2nd, 3rd, …
    /// blank lines as extra vertical space.
    ///
    /// REFERENCE (future "rigorous" Read mode): to mimic Edit mode's layout
    /// exactly, emit a spacer for EVERY blank line (`spacers = blanks`, not
    /// `blanks - 1`). That preserves the author's spacing literally but fights
    /// the HTML/CSS box model (blocks already carry their own margins), so it's
    /// parked until Read mode commits to a styled-source rather than a rendered-
    /// document model. See the discussion in the handoff notes.
    ///
    /// QUIRK: a block's `range.upperBound.line` is NOT reliably its last content
    /// line — cmark folds trailing blank lines into some block ranges (lists in
    /// particular), so a list followed by a blank line then a paragraph reports
    /// the list ending on the blank line. We therefore clamp each block's end
    /// back to its last non-blank source line; the blank run between blocks A and
    /// B is then `B.firstLine - clamp(A.end) - 1`.
    mutating func visitDocument(_ document: Document) -> String {
        var out = ""
        var prevEndLine: Int?
        for child in document.children {
            if options.preserveBlankLines, let prevEndLine, let range = child.range {
                let blanks = range.lowerBound.line - prevEndLine - 1
                if blanks > 1 {
                    out += String(repeating: "<div class=\"blank-line\"></div>", count: blanks - 1)
                }
            }
            var html = visit(child)
            if let range = child.range {
                html = addingAnchorID(html, line: range.lowerBound.line)
            }
            out += html
            if options.preserveBlankLines, let range = child.range {
                prevEndLine = lastContentLine(atOrBefore: range.upperBound.line)
            }
        }
        return out
    }

    /// Inserts `id="edmund-l<line>"` into the first opening tag of `html` — the
    /// tag for a top-level block (`<p>`, `<ul>`, a raw `<div>` HTML block, …) —
    /// so Read mode can scroll to the block whose source starts at `line` and
    /// the editor can find the anchor nearest a given viewport line (see
    /// `ReadModeAnchors`). Skips (returns `html` unchanged) when there's no tag
    /// to anchor: empty (footnote-definition paragraphs render `""`), a closing
    /// tag, or a `<!--`/`<!DOCTYPE` declaration — none of which should happen
    /// for a top-level block, but the guard is cheap insurance against ever
    /// emitting broken markup. A block whose visitor returns multiple sibling
    /// elements (callouts: the callout `<div>` plus a lazy-tail sibling) only
    /// gets the id on the first one, which is correct — that's the element that
    /// starts at `line`.
    private func addingAnchorID(_ html: String, line: Int) -> String {
        guard html.hasPrefix("<"), !html.hasPrefix("</"), !html.hasPrefix("<!") else { return html }
        var idx = html.index(after: html.startIndex)
        while idx < html.endIndex, html[idx].isLetter || html[idx].isNumber {
            idx = html.index(after: idx)
        }
        guard idx > html.index(after: html.startIndex) else { return html }
        return String(html[..<idx]) + " id=\"edmund-l\(line)\"" + String(html[idx...])
    }

    /// The last source line at or before `line` (1-indexed) that has non-blank
    /// content. Used to undo cmark folding trailing blank lines into a block.
    private func lastContentLine(atOrBefore line: Int) -> Int {
        var l = min(line, sourceLines.count)
        while l >= 1, sourceLines[l - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            l -= 1
        }
        return l
    }

    // MARK: Default / children

    mutating func defaultVisit(_ markup: Markup) -> String {
        renderChildren(of: markup)
    }

    private mutating func renderChildren(of markup: Markup) -> String {
        var out = ""
        for child in markup.children { out += visit(child) }
        return out
    }

    // MARK: Block-level

    mutating func visitParagraph(_ paragraph: Paragraph) -> String {
        // A paragraph that is wholly `$$…$$` is a display-math block. Reuse the
        // editor's detector so Read mode and Edit mode agree on what's math.
        // Detect on the *raw* source, not `plainText`: swift-markdown has already
        // applied Markdown backslash-unescaping to a Text node's `.string`
        // (`\\`→`\`, `\$`→`$`), which corrupts LaTeX row separators and commands
        // — so a `\begin{aligned}…\\…\end{aligned}` block would be mangled. The
        // editor's styling reads from raw source by range for the same reason.
        let raw = sourceText(paragraph) ?? Self.plainText(of: paragraph)
        var dm: [SyntaxHighlighter.Span] = []
        SyntaxHighlighter.parseDisplayMath(raw, into: &dm)
        if let span = dm.first(where: { if case .math(true) = $0.kind { return true }; return false }) {
            // Only when the `$$…$$` run is the *whole* paragraph (ignoring
            // surrounding whitespace). Otherwise a `$$` sitting inside inline code
            // (`` `$$a+b$$` ``) or amid prose would wrongly replace the entire
            // paragraph with a math block, blanking its text. Mirrors edit mode's
            // `displayOwnsBlock` so the two views agree.
            let ns = raw as NSString
            let nonWS = CharacterSet.whitespacesAndNewlines.inverted
            let firstNonWS = ns.rangeOfCharacter(from: nonWS).location
            let lastNonWS = ns.rangeOfCharacter(from: nonWS, options: .backwards).location
            if firstNonWS != NSNotFound,
               span.fullRange.location == firstNonWS,
               span.fullRange.upperBound == lastNonWS + 1 {
                let tex = ns.substring(with: span.contentRange)
                return "<div class=\"math-display\" data-tex=\"\(Self.attr(tex))\"></div>"
            }
        }

        // A `[^id]: body` paragraph (the marker starts the paragraph's first
        // Text child) is a footnote definition, not visible content — collect it
        // for the bottom-of-page footnotes section instead of rendering in place.
        let children = Array(paragraph.children)
        if options.features.contains(.footnote),
           let first = children.first as? Text,
           let (id, markerLength) = Self.footnoteDefinitionMarker(in: first.string) {
            var bodyHTML = Self.renderInline(String(first.string.dropFirst(markerLength)),
                                             features: options.features)
            for child in children.dropFirst() { bodyHTML += visit(child) }
            footnotes.append((id: id, bodyHTML: bodyHTML))
            return ""
        }
        return "<p>\(renderChildren(of: paragraph))</p>"
    }

    mutating func visitHeading(_ heading: Heading) -> String {
        let level = min(max(heading.level, 1), 6)
        return "<h\(level)>\(renderChildren(of: heading))</h\(level)>"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        // Per-token syntax coloring reuses the editor's `CodeHighlighter`, so
        // Edit mode and Read mode color the same tokens identically (the actual
        // colors live in CSS, from the shared `CodeSyntaxPalette` via HTMLTheme).
        let lang = codeBlock.language.map { " class=\"language-\(Self.attr($0))\"" } ?? ""
        // QUIRK: U+2028 LINE SEPARATOR and U+2029 PARAGRAPH SEPARATOR are valid
        // Unicode line-ending characters that appear in macOS-pasted text (e.g.
        // from Notes or Safari). In HTML they are NOT newline characters — inside
        // a <pre> block they render as spaces or nothing, concatenating lines that
        // should appear on separate rows. Normalize to plain U+000A before escaping.
        let raw = codeBlock.code
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
        // swift-markdown includes a trailing newline on the block's code.
        let code = raw.hasSuffix("\n") ? String(raw.dropLast()) : raw
        if options.features.contains(.mermaid),
           MermaidSyntax.matches(language: codeBlock.language) {
            // Keep this AST renderer pure: the AppKit-backed native renderer
            // fills the base64 payload in DocumentHTML's asset pass.
            let source = Data(code.utf8).base64EncodedString()
            return "<div class=\"mermaid-diagram\" data-source=\"\(source)\"></div>"
        }
        let pre = "<pre><code\(lang)>\(Self.highlightCode(code, language: codeBlock.language))</code></pre>"
        return "<div class=\"code-block-wrap\">\(Self.copyButtonHTML(code: code))\(pre)</div>"
    }

    /// A code block's copy button: a bare icon, hidden until the block is
    /// hovered (see `.code-copy-icon` in HTMLTheme.swift) — matches
    /// Obsidian's read-mode/preview treatment (misc/frontend-refs/obsidian-
    /// code-block-read-mode-onhover.png), which shows no language name, only
    /// a hover-revealed icon. The click is intercepted natively (never
    /// actually navigates); the base64 payload is decoded and written to the
    /// pasteboard by `ReadModeNavigationPolicy`/`ReadModeWebView`.
    private static func copyButtonHTML(code: String) -> String {
        let b64 = Data(code.utf8).base64EncodedString()
        let encoded = b64.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? b64
        let href = "\(copyScheme):\(encoded)"
        let icon = LucideIcons.inlineSVG("copy") ?? ""
        return "<a class=\"code-copy-btn code-copy-icon\" href=\"\(attr(href))\">\(icon)</a>"
    }

    /// CSS class for a code token kind (consumed by `HTMLTheme`'s `.tok-*` rules).
    private static func tokenClass(_ type: CodeHighlighter.TokenType) -> String {
        switch type {
        case .keyword:   return "tok-keyword"
        case .command:   return "tok-command"
        case .type:      return "tok-type"
        case .attribute: return "tok-attribute"
        case .variable:  return "tok-variable"
        case .value:     return "tok-value"
        case .number:    return "tok-number"
        case .string:    return "tok-string"
        case .comment:   return "tok-comment"
        }
    }

    /// Escapes `code` and wraps each `CodeHighlighter` token in a colored
    /// `<span class="tok-…">`. Gaps between tokens stay plain (escaped) text and
    /// inherit the plain `pre code` color, mirroring the editor's "plain first,
    /// tokens paint over" model.
    static func highlightCode(_ code: String, language: String?) -> String {
        let tokens = CodeHighlighter.tokenize(code, language: language)
        guard !tokens.isEmpty else { return escape(code) }
        let ns = code as NSString
        var out = ""
        var cursor = 0
        for token in tokens {
            let r = token.range
            guard r.location >= cursor, r.upperBound <= ns.length else { continue }
            if r.location > cursor {
                out += escape(ns.substring(with: NSRange(location: cursor, length: r.location - cursor)))
            }
            out += "<span class=\"\(tokenClass(token.type))\">\(escape(ns.substring(with: r)))</span>"
            cursor = r.upperBound
        }
        if cursor < ns.length {
            out += escape(ns.substring(with: NSRange(location: cursor, length: ns.length - cursor)))
        }
        return out
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String { "<hr>" }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> String {
        // Detect a GFM callout (`> [!type] …`) on the first line, the same way
        // the editor does (Callout.parseMarker over the de-quoted first line).
        if options.features.contains(.callout), let inner = deQuoted(blockQuote) {
            let firstLine = String(inner.prefix(while: { $0 != "\n" }))
            if let marker = Callout.parseMarker(firstLine),
               let style = Callout.style(for: marker.type),
               // Obsidian-only types are non-GFM (see calloutInfo): with the
               // master switch off only the 5 GFM alert types stay callouts.
               Callout.isGFMAlert(marker.type) || options.features.contains(.calloutExtendedTypes) {
                return renderCallout(marker: marker, style: style,
                                     firstLine: firstLine, blockQuote: blockQuote)
            }
        }
        return "<blockquote>\(renderChildren(of: blockQuote))</blockquote>"
    }

    /// GFM §5.3: a list is LOOSE iff any two adjacent blocks inside it — between
    /// items, or between blocks within one item — are separated by a blank source
    /// line. swift-markdown doesn't expose cmark's tight flag; recover it from
    /// source-line gaps, clamping each block's end past cmark's folded trailing
    /// blanks (same trick as visitDocument).
    private func isTight(_ list: Markup) -> Bool {
        var prevEnd: Int? = nil
        for item in list.children {
            guard let r = item.range else { continue }
            if let p = prevEnd, r.lowerBound.line - p > 1 { return false }
            var innerPrev: Int? = nil
            for block in item.children {
                guard let br = block.range else { continue }
                if let ip = innerPrev, br.lowerBound.line - ip > 1 { return false }
                innerPrev = lastContentLine(atOrBefore: br.upperBound.line)
            }
            prevEnd = lastContentLine(atOrBefore: r.upperBound.line)
        }
        return true
    }

    mutating func visitUnorderedList(_ list: UnorderedList) -> String {
        listIsTight.append(isTight(list))
        defer { listIsTight.removeLast() }
        return "<ul>\(renderChildren(of: list))</ul>"
    }

    mutating func visitOrderedList(_ list: OrderedList) -> String {
        listIsTight.append(isTight(list))
        defer { listIsTight.removeLast() }
        let start = list.startIndex == 1 ? "" : " start=\"\(list.startIndex)\""
        return "<ol\(start)>\(renderChildren(of: list))</ol>"
    }

    mutating func visitListItem(_ listItem: ListItem) -> String {
        if let checkbox = listItem.checkbox {
            let checked = checkbox == .checked
            // Composed Lucide SVG (not an SF Symbol, which can't ship in exported
            // PDFs) mirroring the editor's look; CSS supplies the accent/dim color.
            let mark = "<span class=\"task-check task-check--\(checked ? "checked" : "unchecked")\">"
                + "\(LucideIcons.checkboxSVG(checked: checked))</span>"
            let checkedClass = checked ? " task--checked" : ""
            return "<li class=\"task\(checkedClass)\">\(mark)\(renderListItemContents(listItem))</li>"
        }
        return "<li>\(renderListItemContents(listItem))</li>"
    }

    /// Item contents; in a tight list, each direct Paragraph child loses its
    /// <p></p> wrapper (visit-then-strip, so visitParagraph's math/footnote
    /// special cases still run).
    private mutating func renderListItemContents(_ item: ListItem) -> String {
        guard listIsTight.last == true else { return renderChildren(of: item) }
        var out = ""
        for child in item.children {
            var html = visit(child)
            if child is Paragraph, html.hasPrefix("<p>"), html.hasSuffix("</p>") {
                html = String(html.dropFirst(3).dropLast(4))
            }
            out += html
        }
        return out
    }

    mutating func visitTable(_ table: Table) -> String {
        let aligns = table.columnAlignments
        func cellStyle(_ col: Int) -> String {
            guard col < aligns.count, let a = aligns[col] else { return "" }
            switch a {
            case .left:   return " style=\"text-align:left\""
            case .center: return " style=\"text-align:center\""
            case .right:  return " style=\"text-align:right\""
            }
        }
        var html = "<div class=\"table-wrap\"><table><thead><tr>"
        for (col, cell) in table.head.cells.enumerated() {
            html += "<th\(cellStyle(col))>\(renderChildren(of: cell))</th>"
        }
        html += "</tr></thead><tbody>"
        for row in table.body.rows {
            html += "<tr>"
            for (col, cell) in row.cells.enumerated() {
                html += "<td\(cellStyle(col))>\(renderChildren(of: cell))</td>"
            }
            html += "</tr>"
        }
        html += "</tbody></table></div>"
        return html
    }

    // MARK: Inline

    mutating func visitText(_ text: Text) -> String {
        Self.renderInline(text.string, rawSource: sourceText(text), features: options.features)
    }
    mutating func visitEmphasis(_ emphasis: Emphasis) -> String { "<em>\(renderChildren(of: emphasis))</em>" }
    mutating func visitStrong(_ strong: Strong) -> String { "<strong>\(renderChildren(of: strong))</strong>" }
    mutating func visitStrikethrough(_ s: Strikethrough) -> String { "<del>\(renderChildren(of: s))</del>" }
    mutating func visitInlineCode(_ code: InlineCode) -> String { "<code>\(Self.escape(code.code))</code>" }
    mutating func visitLineBreak(_ lineBreak: LineBreak) -> String { "<br>\n" }
    // Off → each single newline becomes a literal break (Edit ▸ Strict line breaks).
    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> String {
        options.strictLineBreaks ? "\n" : "<br>\n"
    }

    mutating func visitLink(_ link: Link) -> String {
        let dest = link.destination ?? ""
        let inner = renderChildren(of: link)
        let title = link.title.map { " title=\"\(Self.attr($0))\"" } ?? ""
        // In-page `#fragment` anchors and external links (http/https/mailto, or
        // any explicit scheme) keep their real href — the nav policy lets the
        // anchor scroll and hands external schemes to the browser. A relative /
        // internal destination is wrapped in the private link scheme so it routes
        // through the app's document graph reliably.
        if dest.hasPrefix("#") || Self.hasExternalScheme(dest) {
            return "<a href=\"\(Self.attr(dest))\"\(title)>\(inner)</a>"
        }
        let encoded = dest.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? dest
        return "<a href=\"\(Self.linkScheme):\(encoded)\"\(title)>\(inner)</a>"
    }

    /// Whether a link destination carries an explicit URL scheme (`http:`,
    /// `mailto:`, `file:`, …) and so should be treated as external/absolute
    /// rather than a relative path into the document's directory.
    private static func hasExternalScheme(_ dest: String) -> Bool {
        guard let colon = dest.firstIndex(of: ":") else { return false }
        let scheme = dest[dest.startIndex..<colon]
        // A scheme is letters/digits/+/-/. and can't contain a slash; a path like
        // "a/b:c" has its first colon after a slash, so it's not a scheme.
        guard !scheme.isEmpty, scheme.first!.isLetter else { return false }
        return scheme.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }
            && !scheme.contains("/")
    }

    mutating func visitImage(_ image: Image) -> String {
        // Emit a placeholder carrying the raw source; `DocumentHTML` resolves and
        // inlines it in a second pass (it needs the document directory + the
        // remote-image policy, which the pure renderer doesn't have). No `src`
        // here ⇒ if the asset pass can't resolve it, the alt text shows.
        var altText = Self.plainText(of: image)
        var dims = ""
        // Obsidian image dimensions: `![alt|200](url)` / `![alt|200x100](url)`.
        if options.features.contains(.imageDimensions) {
            let (w, h, stripped) = SyntaxHighlighter.parseImageDimensions(from: altText)
            if w != nil || h != nil { altText = stripped }
            if let w { dims += " width=\"\(w)\"" }
            if let h { dims += " height=\"\(h)\"" }
        }
        let alt = Self.attr(altText)
        let src = Self.attr(image.source ?? "")
        return "<img class=\"md-image\" data-src=\"\(src)\" alt=\"\(alt)\"\(dims)>"
    }

    // Inline HTML (§6.10): full GFM raw-HTML passthrough, filtered through
    // tagfilter (§6.11) + hardening (§G — see ARCHITECTURE §10). Block HTML
    // gets the same filter (below).
    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> String {
        Self.sanitizeInlineHTML(inlineHTML.rawHTML)
    }
    mutating func visitHTMLBlock(_ html: HTMLBlock) -> String {
        // A block-level `<!-- comment -->` is invisible, like in a browser.
        let trimmed = html.rawHTML.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<!--") && trimmed.hasSuffix("-->") { return "" }
        if isSingleTag(trimmed, named: "img"), let img = Self.imgPlaceholder(trimmed) {
            return "<p>\(img)</p>"
        }
        // GFM passthrough (§4.6): tagfilter + hardening, then rewrite interior
        // `<img src=…>` tags to asset-pass placeholders (same baseURL-nil reason
        // as inline; also the remote-image-policy enforcement point). No <p>
        // wrapper, no escaping. filterRawHTML runs FIRST: the placeholders carry
        // only class/data-src/alt/width/height attrs, which the hardening
        // regexes can't touch.
        return Self.rewriteImgs(in: Self.filterRawHTML(html.rawHTML))
    }

    /// Full §6.10 open-tag grammar for `img` (quoted values may contain `>`).
    private static let imgTagRegex = try! NSRegularExpression(
        pattern: #"<img(?:\s+[a-zA-Z_:][a-zA-Z0-9:._-]*(?:\s*=\s*(?:[^\s"'=<>`]+|'[^']*'|"[^"]*"))?)*\s*/?>"#,
        options: [.caseInsensitive])

    /// Replaces every `<img …>` that has a usable src with the md-image
    /// placeholder; src-less imgs pass through untouched (they simply won't load).
    static func rewriteImgs(in html: String) -> String {
        let ns = html as NSString
        let out = NSMutableString(string: html)
        for m in imgTagRegex.matches(in: html, range: NSRange(location: 0, length: ns.length)).reversed() {
            if let placeholder = imgPlaceholder(ns.substring(with: m.range)) {
                out.replaceCharacters(in: m.range, with: placeholder)
            }
        }
        return out as String
    }

    /// True when `raw` is exactly one `<name …>` tag (no trailing content —
    /// the anchored tag regex must consume the whole string).
    private func isSingleTag(_ raw: String, named name: String) -> Bool {
        let ns = raw as NSString
        guard let m = Self.inlineTagRegex.firstMatch(
            in: raw, range: NSRange(location: 0, length: ns.length)) else { return false }
        return ns.substring(with: m.range(at: 1)).isEmpty
            && ns.substring(with: m.range(at: 2)).lowercased() == name
    }

    private static let inlineTagRegex =
        try! NSRegularExpression(pattern: #"^<(/?)([A-Za-z][A-Za-z0-9]*)[^>]*>$"#)

    // MARK: - GFM tagfilter (§6.11) + hardening

    /// Tagfilter (§6.11): the leading `<` of the nine disallowed tag names
    /// (open or closing, case-insensitive) becomes `&lt;`. Lookahead only —
    /// nothing else is consumed.
    private static let tagfilterRegex = try! NSRegularExpression(
        pattern: #"<(?=/?(?:title|textarea|style|xmp|iframe|noembed|noframes|script|plaintext)(?:[\s/>]|$))"#,
        options: [.caseInsensitive])

    /// Hardening (beyond spec): strip `on*` event-handler attributes.
    /// ponytail: plain-text regex, not an HTML parser — a literal ` onclick="x"`
    /// in text between tags is also stripped; harmless for a hardening pass.
    private static let eventAttrRegex = try! NSRegularExpression(
        pattern: #"\son[a-zA-Z]+\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'=<>`]+)"#,
        options: [.caseInsensitive])

    /// Hardening: neutralize javascript:/vbscript: schemes in URL-carrying
    /// attributes (the scheme is deleted; the rest becomes a harmless relative URL).
    private static let scriptURLRegex = try! NSRegularExpression(
        pattern: #"(\s(?:href|src|action|formaction|xlink:href|data)\s*=\s*["']?\s*)(?:javascript|vbscript)\s*:"#,
        options: [.caseInsensitive])

    /// GFM raw-HTML output filter: tagfilter + Edmund's hardening. Defense-in-depth
    /// on top of the read webview's JS-off + CSP script-src 'none' + baseURL nil.
    static func filterRawHTML(_ raw: String) -> String {
        func sub(_ s: String, _ rx: NSRegularExpression, _ template: String) -> String {
            rx.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length),
                                        withTemplate: template)
        }
        var out = sub(raw, tagfilterRegex, "&lt;")
        out = sub(out, eventAttrRegex, "")
        out = sub(out, scriptURLRegex, "$1")
        return out
    }

    /// GFM raw-HTML passthrough (§6.10) with tagfilter (§6.11) + hardening.
    /// Comments stay invisible. A lone `<img src=…>` becomes the asset-pass
    /// placeholder — REQUIRED, not just policy: the page loads with `baseURL: nil`,
    /// so a raw relative `<img src>` could never resolve; the placeholder routes
    /// it through DocumentHTML.fillImages (data-URI inlining + remote-image policy,
    /// declared width/height carried through). Everything else passes through
    /// filtered. Whitelisted formatting tags now keep their (hardened) attributes.
    static func sanitizeInlineHTML(_ raw: String) -> String {
        if raw.hasPrefix("<!--") { return "" }
        let ns = raw as NSString
        if let m = inlineTagRegex.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)),
           ns.substring(with: m.range(at: 1)).isEmpty,                    // open tag
           ns.substring(with: m.range(at: 2)).lowercased() == "img",
           let img = imgPlaceholder(raw) {
            return img
        }
        return filterRawHTML(raw)
    }

    /// A `md-image` placeholder for a raw `<img src="…">` tag, or nil when it
    /// has no `src`. Attribute extraction shares the Edit-mode regexes so the
    /// two back-ends accept the same tags (double-, single-, and unquoted
    /// values, §6.10); every value is re-escaped, so no raw attribute text
    /// passes through.
    static func imgPlaceholder(_ raw: String) -> String? {
        let ns = raw as NSString
        let whole = NSRange(location: 0, length: ns.length)
        func attrValue(_ regex: NSRegularExpression) -> String? {
            regex.firstMatch(in: raw, range: whole)
                .map { ns.substring(with: SyntaxHighlighter.attrValueRange($0)) }
        }
        guard let src = attrValue(SyntaxHighlighter.imgSrcRegex) else { return nil }
        var out = "<img class=\"md-image\" data-src=\"\(attr(src))\""
        out += " alt=\"\(attr(attrValue(SyntaxHighlighter.imgAltRegex) ?? ""))\""
        if let w = attrValue(SyntaxHighlighter.imgWidthRegex) { out += " width=\"\(w)\"" }
        if let h = attrValue(SyntaxHighlighter.imgHeightRegex) { out += " height=\"\(h)\"" }
        return out + ">"
    }

    // MARK: - Callouts

    private mutating func renderCallout(marker: Callout.Marker, style: CalloutStyle,
                                        firstLine: String, blockQuote: BlockQuote) -> String {
        // Custom title = whatever follows `]` (and the fold `-`/`+`) on line 1.
        let ns = firstLine as NSString
        let collapsible = options.features.contains(.collapsibleCallout)
        let fold = collapsible ? marker.fold : nil
        let titleStart = (collapsible ? marker.foldRange?.upperBound : nil) ?? marker.closeBracket.upperBound
        let afterMarker = titleStart <= ns.length ? ns.substring(from: titleStart) : ""
        let title = Callout.title(type: marker.type, customTitle: afterMarker)

        // Callouts are strict: only the leading run of `>`-prefixed lines is the
        // callout body. swift-markdown's CommonMark parse lazily continues a
        // following bare line into the blockquote, but the editor keeps callouts
        // strict (BlockParser splits the lazy line off) so a following
        // `> [!type]` can't be pulled into a prior callout (GFM ex. 228). Split
        // the raw source the same way and render the lazy tail as sibling
        // content after the callout, matching edit-mode segmentation exactly.
        let rawLines = (sourceText(blockQuote) ?? "").components(separatedBy: "\n")
        let quotedCount = rawLines.prefix(while: Self.isQuotedLine).count

        // Body = the de-quoted `>`-run after the first (marker) line, re-parsed.
        let body = rawLines[min(1, quotedCount)..<quotedCount]
            .map(Self.deQuoteLine).joined(separator: "\n")
        let bodyHTML = body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : HTMLRenderer.render(markdown: body, options: options)

        // Inline the Lucide icon directly (vector, sharp in PDF). It strokes in
        // `currentColor`, so the `.callout-title` accent color tints it — no
        // per-appearance asset pass, and no SF Symbol shipped in the export.
        let icon = "<span class=\"callout-icon\">\(LucideIcons.inlineSVG(style.iconName) ?? "")</span>"
        let titleInner = "\(icon)<span class=\"callout-title-text\">\(Self.escape(title))</span>"
        // Collapsible (`[!type]-`/`+`) → a native <details>/<summary> so Read mode
        // actually folds; `-` starts collapsed, `+` starts open. Otherwise a
        // plain <div> as before.
        let calloutHTML: String
        if let fold {
            let openAttr = fold == .expanded ? " open" : ""
            calloutHTML = "<details class=\"callout callout-\(Self.attr(marker.type)) callout-collapsible\"\(openAttr)>"
                + "<summary class=\"callout-title\">\(titleInner)</summary>"
                + "<div class=\"callout-body\">\(bodyHTML)</div></details>"
        } else {
            calloutHTML = "<div class=\"callout callout-\(Self.attr(marker.type))\">"
                + "<div class=\"callout-title\">\(titleInner)</div>"
                + "<div class=\"callout-body\">\(bodyHTML)</div></div>"
        }

        // Lazy tail (bare lines swift-markdown folded in) → sibling markdown.
        let tail = rawLines[quotedCount...].joined(separator: "\n")
        let tailHTML = tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : HTMLRenderer.render(markdown: tail, options: options)
        return calloutHTML + tailHTML
    }

    /// The raw source text of a block quote with each line's `>` prefix removed.
    private func deQuoted(_ blockQuote: BlockQuote) -> String? {
        guard let quoted = sourceText(blockQuote) else { return nil }
        return quoted.components(separatedBy: "\n")
            .map(Self.deQuoteLine).joined(separator: "\n")
    }

    /// Strips one leading `>` marker (optional spaces, `>`, optional space).
    private static func deQuoteLine(_ line: String) -> String {
        var l = Substring(line)
        while l.first == " " { l = l.dropFirst() }
        if l.first == ">" {
            l = l.dropFirst()
            if l.first == " " { l = l.dropFirst() }
        }
        return String(l)
    }

    /// Whether a line carries a `>` marker (optional leading spaces then `>`) —
    /// the same predicate the editor's BlockParser uses for quote membership.
    private static func isQuotedLine(_ line: String) -> Bool {
        line.drop(while: { $0 == " " }).first == ">"
    }

    // MARK: - Inline non-GFM (highlight / math / wikilink / comment)

    /// Renders a leaf text run, recognizing the non-GFM inline constructs the
    /// editor supports by reusing the same custom-parser regexes. Everything not
    /// matched is HTML-escaped.
    ///
    /// `rawSource`, when given, is this run's *unescaped-by-swift-markdown* source
    /// (`Text.string`) counterpart's raw markdown. Only inline math needs it: a
    /// Text node's `.string` has already had Markdown backslash-escapes collapsed
    /// (`\\`→`\`, `\$`→`$`), which mangles LaTeX (a `\begin{cases} … \\ … \end`
    /// loses its row separators). The tex is therefore recovered from the raw
    /// source instead. Everything else stays on the (correctly unescaped) `s`.
    private static func renderInline(_ s: String, rawSource: String? = nil,
                                     features: MarkdownFeatures = .all) -> String {
        guard !s.isEmpty else { return "" }
        var spans: [SyntaxHighlighter.Span] = []
        // Each custom pass is gated by its feature flag, matching the editor's
        // `SyntaxHighlighter.parse`: a cleared flag drops the syntax to plain text.
        if features.contains(.highlight) { SyntaxHighlighter.parseHighlight(s, into: &spans) }
        if features.contains(.math) {
            SyntaxHighlighter.parseDisplayMath(s, into: &spans) // $$…$$ embedded in a prose line
            SyntaxHighlighter.parseMath(s, into: &spans)        // inline $…$ only
        }
        if features.contains(.wikilink) || features.contains(.wikilinkEmbed) {
            SyntaxHighlighter.parseWikiLinks(s, into: &spans, features: features)
        }
        if features.contains(.inlineComment) { SyntaxHighlighter.parseComments(s, into: &spans) }
        if features.contains(.tag) { SyntaxHighlighter.parseTag(s, into: &spans) }
        if features.contains(.blockRef) { SyntaxHighlighter.parseBlockRef(s, into: &spans) }
        if features.contains(.footnote) { SyntaxHighlighter.parseFootnotes(s, into: &spans) }  // references only; a
        // `.footnoteDefinition` match here is a false positive (mid-run text that
        // happens to start with `[^id]:`) since real definitions are handled at
        // the paragraph level in `visitParagraph` — ignored by the switch below.

        // Bare autolinks last, so the guards above are in place. Real `[x](url)`
        // links never appear here (they're Link nodes, not leaf text).
        SyntaxHighlighter.parseAutolinks(s, into: &spans)

        // Keep only the kinds we emit, ordered, non-overlapping (earliest wins).
        let relevant = spans.filter {
            switch $0.kind {
            case .highlight, .math, .wikilink, .comment, .footnoteReference,
                 .link, .image, .embed, .tag, .blockRef: return true
            default: return false
            }
        }.sorted { $0.fullRange.location < $1.fullRange.location }

        // Recover each inline equation's tex from the raw source. The raw parse
        // finds the same `$…$` runs in the same order; pair the k-th emitted math
        // span with the k-th raw one. Only when the counts agree (a `\$` escape
        // can make the unescaped `s` see a spurious `$…$` the raw source doesn't),
        // else fall back to the unescaped tex — no worse than before.
        var rawTexByLoc: [Int: String] = [:]
        if let rawSource {
            let rns = rawSource as NSString
            // Recover both inline `$…$` and display `$$…$$` tex, each paired k-th
            // to k-th with the emitted spans of the same kind.
            func recover(display: Bool) {
                var rawSpans: [SyntaxHighlighter.Span] = []
                if display { SyntaxHighlighter.parseDisplayMath(rawSource, into: &rawSpans) }
                else { SyntaxHighlighter.parseMath(rawSource, into: &rawSpans) }
                let rawTex = rawSpans
                    .filter { if case .math(display) = $0.kind { return true }; return false }
                    .sorted { $0.fullRange.location < $1.fullRange.location }
                    .map { rns.substring(with: $0.contentRange) }
                let emitted = relevant
                    .filter { if case .math(display) = $0.kind { return true }; return false }
                if emitted.count == rawTex.count {
                    for (i, sp) in emitted.enumerated() { rawTexByLoc[sp.fullRange.location] = rawTex[i] }
                }
            }
            recover(display: false)
            recover(display: true)
        }

        let ns = s as NSString
        var out = ""
        var cursor = 0
        for span in relevant {
            let r = span.fullRange
            if r.location < cursor { continue }   // overlaps a prior span
            if r.location > cursor {
                out += escape(ns.substring(with: NSRange(location: cursor, length: r.location - cursor)))
            }
            switch span.kind {
            case .highlight:
                out += "<mark>\(escape(ns.substring(with: span.contentRange)))</mark>"
            case .math(let display):
                let tex = rawTexByLoc[r.location] ?? ns.substring(with: span.contentRange)
                // A `$$…$$` embedded in a prose line renders as display-mode math
                // but flows inline, matching the editor (a wholly-`$$` paragraph is
                // the block case, handled in visitParagraph).
                let cls = display ? "math-display-inline" : "math-inline"
                out += "<span class=\"\(cls)\" data-tex=\"\(attr(tex))\"></span>"
            case .wikilink(let target):
                // Emit a link in a private scheme so the read view's nav policy
                // can intercept it and route through the app's document graph
                // (rather than navigating the webview). The target is fully
                // percent-encoded so a `#heading` isn't parsed as a URL fragment.
                let encoded = target.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? target
                let display = escape(ns.substring(with: span.contentRange))
                out += "<a class=\"wikilink\" href=\"\(wikiScheme):\(encoded)\">\(display)</a>"
            case .footnoteReference(let id):
                let safeID = attr(id)
                out += "<sup id=\"fnref-\(safeID)\" class=\"footnote-ref\">" +
                       "<a href=\"#fn-\(safeID)\">\(escape(id))</a></sup>"
            case .image(let destination, let width, let height):
                // A `![[file]]` wikilink embed: emit the same md-image
                // placeholder as a markdown image (DocumentHTML's asset pass
                // resolves `data-src` relative to the document directory).
                var dims = ""
                if let width { dims += " width=\"\(width)\"" }
                if let height { dims += " height=\"\(height)\"" }
                out += "<img class=\"md-image\" data-src=\"\(attr(destination))\" alt=\"\"\(dims)>"
            case .embed(let destination):
                // A non-image `![[file]]` embed: emit the same blocked-placeholder
                // markup as a blocked image, labelled by the file's type. A
                // non-image embed never resolves to an asset, so no DocumentHTML
                // pass is needed (unlike `.image`).
                let icon = LucideIcons.inlineSVG("file-x") ?? ""
                let label = escape(ImageLoadFailure.forEmbed(destination: destination).label)
                out += "<span class=\"md-image-blocked\">\(icon)<span>\(label)</span></span>"
            case .tag(let name):
                out += "<span class=\"tag\">#\(escape(name))</span>"
            case .blockRef:
                break   // hidden in reading, like a comment
            case .comment:
                break   // hidden in reading, like the editor
            case .link(let destination):
                // A bare autolink: a real external href (http/mailto).
                out += "<a href=\"\(attr(destination))\">\(escape(ns.substring(with: span.contentRange)))</a>"
            default:
                break
            }
            cursor = r.upperBound
        }
        if cursor < ns.length {
            out += escape(ns.substring(with: NSRange(location: cursor, length: ns.length - cursor)))
        }
        return out
    }

    // MARK: - Source-offset helpers (UTF-8 SourceLocation → UTF-16 NSRange)

    private func sourceText(_ markup: Markup) -> String? {
        guard let range = markup.range else { return nil }
        let lo = utf16Offset(for: range.lowerBound)
        let hi = utf16Offset(for: range.upperBound)
        let ns = source as NSString
        guard lo <= hi, hi <= ns.length else { return nil }
        return ns.substring(with: NSRange(location: lo, length: hi - lo))
    }

    private func utf16Offset(for loc: SourceLocation) -> Int {
        var utf8Offset = 0
        for i in 0..<(loc.line - 1) where i < sourceLines.count {
            utf8Offset += sourceLines[i].utf8.count + 1
        }
        utf8Offset += loc.column - 1
        let utf8View = source.utf8
        let targetIdx = utf8View.index(utf8View.startIndex,
                                       offsetBy: min(utf8Offset, utf8View.count))
        return source.utf16.distance(
            from: source.utf16.startIndex,
            to: String.Index(targetIdx, within: source.utf16) ?? source.utf16.endIndex)
    }

    // MARK: - Escaping

    /// Escapes text content for HTML.
    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            default:  out.append(ch)
            }
        }
        return out
    }

    /// Escapes a string for use inside a double-quoted HTML attribute.
    static func attr(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&":  out += "&amp;"
            case "<":  out += "&lt;"
            case ">":  out += "&gt;"
            case "\"": out += "&quot;"
            case "'":  out += "&#39;"
            default:   out.append(ch)
            }
        }
        return out
    }

    /// Concatenates the literal text of a subtree (Text/InlineCode joined,
    /// soft/line breaks as newlines). Used for display-math detection and image
    /// alt text — not for general rendering.
    static func plainText(of markup: Markup) -> String {
        if let t = markup as? Text { return t.string }
        if let c = markup as? InlineCode { return c.code }
        if markup is SoftBreak || markup is LineBreak { return "\n" }
        return markup.children.map { plainText(of: $0) }.joined()
    }

    /// If `text` starts with a footnote definition marker `[^id]:` (optionally
    /// followed by one space), returns the id and the marker's length so the
    /// caller can split it off from the body. Mirrors
    /// `SyntaxHighlighter.parseFootnotes`'s definition rule (which only matches
    /// at the start of the string passed to it) without needing that file's
    /// file-private regex.
    private static func footnoteDefinitionMarker(in text: String) -> (id: String, markerLength: Int)? {
        guard text.hasPrefix("[^"), let closeBracket = text[text.index(text.startIndex, offsetBy: 2)...].firstIndex(of: "]") else { return nil }
        let id = text[text.index(text.startIndex, offsetBy: 2)..<closeBracket]
        guard !id.isEmpty, !id.contains(where: { $0.isWhitespace }) else { return nil }
        let afterBracket = text.index(after: closeBracket)
        guard afterBracket < text.endIndex, text[afterBracket] == ":" else { return nil }
        var markerEnd = text.index(after: afterBracket)
        if markerEnd < text.endIndex, text[markerEnd] == " " { markerEnd = text.index(after: markerEnd) }
        return (String(id), text.distance(from: text.startIndex, to: markerEnd))
    }
}

/// Start/end source lines (1-indexed) of each top-level block, in document
/// order — the same blocks that get `id="edmund-l<start>"` anchors in the
/// rendered HTML. Used to map editor viewport lines to read-mode anchors.
///
/// A public wrapper: `HTMLRenderer` itself stays internal (a public struct
/// would leak its `MarkupVisitor` conformance and rendering internals to
/// other targets), but callers outside EdmundCore need this line mapping.
public enum ReadModeAnchors {

    /// Parses `markdown` with the same options `HTMLRenderer.render` uses, so
    /// the reported spans match the document that's actually rendered.
    public static func topLevelBlockSpans(for markdown: String) -> [(startLine: Int, endLine: Int)] {
        let document = Document(parsing: markdown, options: [.disableSmartOpts])
        return document.children.compactMap { child in
            guard let range = child.range else { return nil }
            return (startLine: range.lowerBound.line, endLine: range.upperBound.line)
        }
    }
}
