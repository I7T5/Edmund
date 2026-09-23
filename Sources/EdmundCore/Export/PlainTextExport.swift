import Foundation

// MARK: - PlainTextExport
//
// File ▸ Export To ▸ Plain Text…: the document's words with the Markdown
// syntax taken out.
//
// Built from the source, not from the rendered HTML like Rich Text. AppKit's
// HTML importer — the obvious shortcut — flattens a table to one cell per
// line, drops list nesting and checkbox state, prints "1" for "1.", and turns
// math into pictures that plain text can't hold. The source still has all of
// that.
//
// What counts as syntax is exactly what Edit mode hides: every
// `SyntaxHighlighter.Span`'s `delimiterRanges`, so this can't drift from the
// editor on what `**`, `==` or `[[a|b]]` mean. Structure a plain-text reader
// still needs is kept in its plain-text form instead of being stripped:
//   - list markers with their indentation (`•`, `1.`, `☐`/`☑` for tasks)
//   - `> ` quote markers, and a callout's header reduced to its title
//   - `---` rules
//   - tables as aligned pipe grids, via the editor's own table aligner
//   - links as `text (url)`, footnotes as `[1]`
// Line structure follows the source line for line (blank lines included), so
// the output keeps the author's paragraphs and spacing.
public enum PlainTextExport {

    public static func text(markdown: String, features: MarkdownFeatures = .all) -> String {
        // Reference links (`[text][label]`) resolve against definitions that
        // may sit in any block — the same append the editor does per block.
        let defs = LinkDefinitionState.build(from: markdown).defsText
        var lines: [String] = []
        // A block that held only hidden things (front matter, a comment, an
        // image without alt text) disappears rather than leaving an empty
        // line — and takes one of the blank lines around it along, so the
        // paragraphs either side keep a single blank line between them.
        var dropped = false
        for block in BlockParser.parse(markdown, features: features) {
            let out: String
            switch block.kind {
            case .frontMatter, .multiBlockComment:
                out = ""   // hidden in Read mode, so not part of the document's text
            case .indentedCode:
                out = block.content
            case .table:
                out = table(block.content, defs: defs, features: features)
            case .htmlBlock:
                out = strippingTags(block.content)
            case .quoteRun(isCallout: true):
                out = strip(calloutTitled(block.content, features: features),
                            defs: defs, features: features)
            default:
                out = strip(block.content, defs: defs, features: features)
            }
            if out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if block.kind != .blank { dropped = true; continue }
                if dropped, lines.last?.isEmpty == true { dropped = false; continue }
            }
            dropped = false
            lines.append(out)
        }
        let body = lines.joined(separator: "\n")
            .components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
        return body.isEmpty ? "" : body + "\n"
    }

    // MARK: Inline syntax

    /// `text` with its inline syntax removed and its list/footnote/link markup
    /// rewritten to the plain-text forms listed in the header.
    static func strip(_ text: String, defs: String = "", features: MarkdownFeatures) -> String {
        let ns = text as NSString
        var edits: [(range: NSRange, text: String)] = []
        for span in SyntaxHighlighter.parse(text, linkDefinitions: defs, features: features) {
            let delims = span.delimiterRanges
            switch span.kind {
            case .comment, .blockRef, .htmlTag:
                edits.append((span.fullRange, ""))   // hidden in Read mode
            case .embed:
                // A non-image `![[file]]` has no delimiters; its name is its text.
                edits.append((span.fullRange, ns.substring(with: span.contentRange)))
            case .image:
                // The picture's text stand-in is its alt text. Not via the
                // delimiters: `![](src)` (what a paste inserts) and `<img>` both
                // report none, with the whole token as content.
                let token = ns.substring(with: span.fullRange)
                let alt: String
                if token.hasPrefix("<") {
                    alt = token.range(of: #"(?<=\balt\s{0,3}=\s{0,3}["'])[^"']*"#,
                                      options: [.regularExpression, .caseInsensitive])
                        .map { String(token[$0]) } ?? ""
                } else {
                    alt = delims.isEmpty ? "" : ns.substring(with: span.contentRange)
                }
                edits.append((span.fullRange, alt))
            case .footnoteReference(let id), .footnoteDefinition(let id):
                // `[^1]` / `[^1]:` → `[1]`, the plain-text footnote convention.
                edits.append((span.fullRange, "[\(id)]"))
            case .link(let destination):
                // Keep where it points, unless the text already says it or it
                // only points inside this document.
                let label = ns.substring(with: span.contentRange)
                let showURL = !destination.isEmpty && !destination.hasPrefix("#")
                    && destination != label && "mailto:" + label != destination
                for (i, r) in delims.enumerated() {
                    edits.append((r, i == delims.count - 1 && showURL ? " (\(destination))" : ""))
                }
            case .listItem(let ordered, let checkbox):
                guard let marker = delims.first else { continue }
                let raw = ns.substring(with: marker)
                let indent = String(raw.prefix { $0 == " " || $0 == "\t" })
                let symbol: String
                switch (checkbox, ordered) {
                case (.checked?, _):   symbol = "☑"
                case (.unchecked?, _): symbol = "☐"
                case (nil, true):      symbol = raw.trimmingCharacters(in: .whitespaces)   // "1." as written
                case (nil, false):     symbol = "•"
                }
                edits.append((marker, indent + symbol + " "))
            case .math(display: true):
                // `$$` on their own lines would leave blank lines behind.
                edits.append((span.fullRange, ns.substring(with: span.contentRange)
                                .trimmingCharacters(in: .newlines)))
            case .blockquote, .thematicBreak, .table:
                break   // `> ` and `---` are plain-text conventions; tables are handled whole
            default:
                edits += delims.map { ($0, "") }
            }
        }
        return applying(edits, to: ns)
    }

    /// Applies non-overlapping edits back to front. When two overlap (a comment
    /// that contains bold), the outer, earlier one wins and the inner is
    /// dropped — it sat inside text that is being removed anyway.
    private static func applying(_ edits: [(range: NSRange, text: String)], to ns: NSString) -> String {
        let ordered = edits.sorted {
            $0.range.location != $1.range.location ? $0.range.location < $1.range.location
                                                   : $0.range.length > $1.range.length
        }
        var kept: [(range: NSRange, text: String)] = []
        var end = 0
        for edit in ordered where edit.range.location >= end {
            kept.append(edit)
            end = max(end, edit.range.upperBound)
        }
        let out = NSMutableString(string: ns)
        for edit in kept.reversed() { out.replaceCharacters(in: edit.range, with: edit.text) }
        return out as String
    }

    // MARK: Blocks

    /// A table as an aligned pipe grid: each cell's inline syntax stripped,
    /// then padded by `prettyAlignedTableLines` — the aligner the editor uses
    /// when it builds a table. The source's own spacing is not trusted:
    /// Edmund only tidies pipes on paste/structural edits and never pads
    /// columns (`normalizedTableRow`), so tables on disk are rarely aligned.
    ///
    /// ponytail: widths count Characters, so CJK/emoji cells misalign in a
    /// monospaced view — the same ceiling as the editor's aligner; share an
    /// East-Asian-width measure between the two if it matters.
    static func table(_ text: String, defs: String = "", features: MarkdownFeatures) -> String {
        let lines = text.components(separatedBy: "\n")
        let rows = lines.enumerated().map { i, line -> String in
            guard i != 1 else { return line }   // separator: keeps the alignment colons
            let ns = line as NSString
            let cells = columnSpans(in: ns).map { span -> String in
                let raw = ns.substring(with: NSRange(location: span.start, length: span.end - span.start))
                    .trimmingCharacters(in: .whitespaces)
                // An escaped `\|` strips to a bare pipe, which would split the
                // cell when the aligner re-reads the row — keep it escaped.
                return strip(raw, defs: defs, features: features)
                    .replacingOccurrences(of: "|", with: "\\|")
            }
            return "| " + cells.joined(separator: " | ") + " |"
        }
        return prettyAlignedTableLines(rows).joined(separator: "\n")
    }

    /// A callout's `[!type]` header reduced to the title Edit and Read mode
    /// show for it (the custom title, else the capitalized type).
    private static func calloutTitled(_ text: String, features: MarkdownFeatures) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let first = lines.first,
              let quote = first.range(of: #"^[ \t]*(>[ \t]?)+"#, options: .regularExpression)
        else { return text }
        let prefix = String(first[quote])
        let rest = String(first[quote.upperBound...])
        guard let marker = Callout.parseMarker(rest) else { return text }
        let ns = rest as NSString
        // Mirror Edit mode: the fold char is syntax only while the feature is on.
        let titleStart = features.contains(.collapsibleCallout)
            ? (marker.foldRange?.upperBound ?? marker.closeBracket.upperBound)
            : marker.closeBracket.upperBound
        let custom = ns.substring(from: titleStart)
        lines[0] = prefix + Callout.title(type: marker.type, customTitle: custom)
        return lines.joined(separator: "\n")
    }

    /// Raw HTML blocks keep their text; tags, comments and script/style bodies
    /// go, and so do lines that held nothing but markup.
    private static func strippingTags(_ html: String) -> String {
        html.replacingOccurrences(of: #"<(script|style)\b[\s\S]*?</\1\s*>"#, with: "",
                                  options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
            .components(separatedBy: "\n")
            .filter { line in
                !line.trimmingCharacters(in: .whitespaces).isEmpty
                    && !line.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespaces).isEmpty
            }
            .map { $0.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression) }
            .joined(separator: "\n")
    }
}
