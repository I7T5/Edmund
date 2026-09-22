import Foundation

extension HTMLRenderer {

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
    static func renderInline(_ s: String, rawSource: String? = nil,
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
}
