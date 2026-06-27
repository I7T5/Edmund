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

    /// The markdown this instance is rendering. Held so block-level constructs
    /// (callouts) can recover their *raw* source text by range, the way the
    /// editor's styling layer does.
    private let source: String
    private let sourceLines: [String]
    private let options: ReadRenderOptions

    private init(source: String, options: ReadRenderOptions) {
        self.source = source
        self.sourceLines = source.components(separatedBy: "\n")
        self.options = options
    }

    /// Parses `markdown` and returns the rendered HTML body (no `<html>`/`<head>`
    /// wrapper — `DocumentHTML` adds that).
    static func render(markdown: String, options: ReadRenderOptions = .default) -> String {
        var r = HTMLRenderer(source: markdown, options: options)
        let doc = Document(parsing: markdown, options: [.disableSmartOpts])
        return r.visit(doc)
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
        guard options.preserveBlankLines else { return renderChildren(of: document) }
        var out = ""
        var prevEndLine: Int?
        for child in document.children {
            if let prevEndLine, let range = child.range {
                let blanks = range.lowerBound.line - prevEndLine - 1
                if blanks > 1 {
                    out += String(repeating: "<div class=\"blank-line\"></div>", count: blanks - 1)
                }
            }
            out += visit(child)
            if let range = child.range {
                prevEndLine = lastContentLine(atOrBefore: range.upperBound.line)
            }
        }
        return out
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
        let raw = Self.plainText(of: paragraph)
        var dm: [SyntaxHighlighter.Span] = []
        SyntaxHighlighter.parseDisplayMath(raw, into: &dm)
        if let span = dm.first(where: { if case .math(true) = $0.kind { return true }; return false }) {
            let tex = (raw as NSString).substring(with: span.contentRange)
            return "<div class=\"math-display\" data-tex=\"\(Self.attr(tex))\"></div>"
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
        return "<pre><code\(lang)>\(Self.highlightCode(code, language: codeBlock.language))</code></pre>"
    }

    /// CSS class for a code token kind (consumed by `HTMLTheme`'s `.tok-*` rules).
    private static func tokenClass(_ type: CodeHighlighter.TokenType) -> String {
        switch type {
        case .keyword:  return "tok-keyword"
        case .type:     return "tok-type"
        case .string:   return "tok-string"
        case .number:   return "tok-number"
        case .comment:  return "tok-comment"
        case .function: return "tok-function"
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
        if let inner = deQuoted(blockQuote) {
            let firstLine = String(inner.prefix(while: { $0 != "\n" }))
            if let marker = Callout.parseMarker(firstLine),
               let style = Callout.style(for: marker.type) {
                return renderCallout(marker: marker, style: style,
                                     firstLine: firstLine, inner: inner)
            }
        }
        return "<blockquote>\(renderChildren(of: blockQuote))</blockquote>"
    }

    mutating func visitUnorderedList(_ list: UnorderedList) -> String {
        "<ul>\(renderChildren(of: list))</ul>"
    }

    mutating func visitOrderedList(_ list: OrderedList) -> String {
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
            return "<li class=\"task\(checkedClass)\">\(mark)\(renderChildren(of: listItem))</li>"
        }
        return "<li>\(renderChildren(of: listItem))</li>"
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
        var html = "<table><thead><tr>"
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
        html += "</tbody></table>"
        return html
    }

    // MARK: Inline

    mutating func visitText(_ text: Text) -> String { Self.renderInline(text.string) }
    mutating func visitEmphasis(_ emphasis: Emphasis) -> String { "<em>\(renderChildren(of: emphasis))</em>" }
    mutating func visitStrong(_ strong: Strong) -> String { "<strong>\(renderChildren(of: strong))</strong>" }
    mutating func visitStrikethrough(_ s: Strikethrough) -> String { "<del>\(renderChildren(of: s))</del>" }
    mutating func visitInlineCode(_ code: InlineCode) -> String { "<code>\(Self.escape(code.code))</code>" }
    mutating func visitLineBreak(_ lineBreak: LineBreak) -> String { "<br>\n" }
    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> String { "\n" }

    mutating func visitLink(_ link: Link) -> String {
        let dest = link.destination ?? ""
        let inner = renderChildren(of: link)
        // In-page `#fragment` anchors and external links (http/https/mailto, or
        // any explicit scheme) keep their real href — the nav policy lets the
        // anchor scroll and hands external schemes to the browser. A relative /
        // internal destination is wrapped in the private link scheme so it routes
        // through the app's document graph reliably (independent of how WebKit
        // rewrites relative hrefs under `baseURL: nil`).
        if dest.hasPrefix("#") || Self.hasExternalScheme(dest) {
            return "<a href=\"\(Self.attr(dest))\">\(inner)</a>"
        }
        let encoded = dest.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? dest
        return "<a href=\"\(Self.linkScheme):\(encoded)\">\(inner)</a>"
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
        let alt = Self.attr(Self.plainText(of: image))
        let src = Self.attr(image.source ?? "")
        return "<img class=\"md-image\" data-src=\"\(src)\" alt=\"\(alt)\">"
    }

    // Inline HTML: a whitelisted formatting tag (u/kbd/mark/sub/sup) passes
    // through so the browser renders it; every other tag is escaped to literal
    // text. Block HTML is always escaped (below) — a document still can't inject
    // markup/script (§G).
    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> String {
        Self.sanitizeInlineHTML(inlineHTML.rawHTML)
    }
    mutating func visitHTMLBlock(_ html: HTMLBlock) -> String { "<p>\(Self.escape(html.rawHTML))</p>" }

    private static let inlineTagRegex =
        try! NSRegularExpression(pattern: #"^<(/?)([A-Za-z][A-Za-z0-9]*)[^>]*>$"#)

    /// Passes a whitelisted inline tag through as a sanitized *bare* tag (`<u>` /
    /// `</u>`, attributes dropped); escapes anything else. The read webview
    /// disables JavaScript, but dropping attributes is defense-in-depth against
    /// attribute-based injection (`<mark onmouseover=…>`). Mirrors the Edit-mode
    /// whitelist via `SyntaxHighlighter.htmlFormatTags`.
    static func sanitizeInlineHTML(_ raw: String) -> String {
        let ns = raw as NSString
        if let m = inlineTagRegex.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) {
            let isClose = ns.substring(with: m.range(at: 1)) == "/"
            let name = ns.substring(with: m.range(at: 2)).lowercased()
            if SyntaxHighlighter.htmlFormatTags.contains(name) {
                return isClose ? "</\(name)>" : "<\(name)>"
            }
        }
        return escape(raw)
    }

    // MARK: - Callouts

    private mutating func renderCallout(marker: Callout.Marker, style: CalloutStyle,
                                        firstLine: String, inner: String) -> String {
        // Custom title = whatever follows `]` on the first line.
        let ns = firstLine as NSString
        let afterMarker = marker.closeBracket.upperBound <= ns.length
            ? ns.substring(from: marker.closeBracket.upperBound)
            : ""
        let title = Callout.title(type: marker.type, customTitle: afterMarker)

        // Body = the de-quoted content after the first line, re-parsed and
        // rendered fresh (mirrors the editor stripping `>` and re-parsing).
        let body: String
        if let nl = inner.firstIndex(of: "\n") {
            body = String(inner[inner.index(after: nl)...])
        } else {
            body = ""
        }
        let bodyHTML = body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : HTMLRenderer.render(markdown: body, options: options)

        // Inline the Lucide icon directly (vector, sharp in PDF). It strokes in
        // `currentColor`, so the `.callout-title` accent color tints it — no
        // per-appearance asset pass, and no SF Symbol shipped in the export.
        let icon = "<span class=\"callout-icon\">\(LucideIcons.inlineSVG(style.iconName) ?? "")</span>"
        return "<div class=\"callout callout-\(Self.attr(marker.type))\">"
            + "<div class=\"callout-title\">\(icon)<span class=\"callout-title-text\">\(Self.escape(title))</span></div>"
            + "<div class=\"callout-body\">\(bodyHTML)</div></div>"
    }

    /// The raw source text of a block quote with each line's `>` prefix removed.
    private func deQuoted(_ blockQuote: BlockQuote) -> String? {
        guard let quoted = sourceText(blockQuote) else { return nil }
        let lines = quoted.components(separatedBy: "\n").map { line -> String in
            var l = Substring(line)
            while l.first == " " { l = l.dropFirst() }
            if l.first == ">" {
                l = l.dropFirst()
                if l.first == " " { l = l.dropFirst() }
            }
            return String(l)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Inline non-GFM (highlight / math / wikilink / comment)

    /// Renders a leaf text run, recognizing the non-GFM inline constructs the
    /// editor supports by reusing the same custom-parser regexes. Everything not
    /// matched is HTML-escaped.
    private static func renderInline(_ s: String) -> String {
        guard !s.isEmpty else { return "" }
        var spans: [SyntaxHighlighter.Span] = []
        SyntaxHighlighter.parseHighlight(s, into: &spans)
        SyntaxHighlighter.parseMath(s, into: &spans)        // inline $…$ only
        SyntaxHighlighter.parseWikiLinks(s, into: &spans)
        SyntaxHighlighter.parseComments(s, into: &spans)

        // Keep only the kinds we emit, ordered, non-overlapping (earliest wins).
        let relevant = spans.filter {
            switch $0.kind {
            case .highlight, .math(false), .wikilink, .comment: return true
            default: return false
            }
        }.sorted { $0.fullRange.location < $1.fullRange.location }

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
            case .math(false):
                let tex = ns.substring(with: span.contentRange)
                out += "<span class=\"math-inline\" data-tex=\"\(attr(tex))\"></span>"
            case .wikilink(let target):
                // Emit a link in a private scheme so the read view's nav policy
                // can intercept it and route through the app's document graph
                // (rather than navigating the webview). The target is fully
                // percent-encoded so a `#heading` isn't parsed as a URL fragment.
                let encoded = target.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? target
                let display = escape(ns.substring(with: span.contentRange))
                out += "<a class=\"wikilink\" href=\"\(wikiScheme):\(encoded)\">\(display)</a>"
            case .comment:
                break   // hidden in reading, like the editor
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
}
