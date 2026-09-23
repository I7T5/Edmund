import Foundation
import Markdown

// MARK: - SelfContainedMarkdown
//
// Rewrites a markdown document so every locally-referenced image is embedded
// as a base64 data URI — the "one file you can just send someone" share copy.
// The working document keeps its sibling-assets relative paths; this transform
// produces a separate artifact (File ▸ Export To ▸ Markdown with Embedded Images…).
//
// What gets rewritten, and what doesn't:
//   - `![alt](local/path.png)`     → `![alt](data:image/png;base64,…)`
//   - `<img src="local/path.png">` → src replaced, rest of the tag untouched
//   - `![[local.png]]` embed       → `![](data:…)` (syntax changes; the picture
//                                    is what matters in a share copy)
//   - Remote (`http(s)`) and `data:` sources, missing files, non-image embeds
//     (`![[note.pdf]]`), and anything inside code blocks / inline code pass
//     through unchanged.
//
// Block-aware, never regex-over-the-whole-file: the document is split by
// `BlockParser`, code-ish blocks are skipped, and each remaining block is
// parsed with swift-markdown so image tokens inside inline code (`` `![](x)` ``)
// are never mistaken for real images.
public enum SelfContainedMarkdown {

    /// Returns `markdown` with every resolvable local image inlined as a data
    /// URI. `baseURL` is the document's directory; nil (an unsaved document)
    /// means no relative path can resolve, so the input is returned unchanged.
    public static func inlineLocalImages(markdown: String, baseURL: URL?,
                                         features: MarkdownFeatures = .all) -> String {
        guard let baseURL else { return markdown }
        // (range in markdown coordinates, replacement text), applied
        // back-to-front at the end so earlier ranges stay valid.
        var edits: [(NSRange, String)] = []

        for block in BlockParser.parse(markdown, features: features) {
            switch block.kind {
            case .fence, .indentedCode, .mathDisplay, .multiBlockComment:
                continue
            default:
                break
            }
            let content = block.content
            let base = block.range.location

            var collector = InlineImageCollector(source: content)
            collector.visit(Document(parsing: content, options: [.disableSmartOpts]))

            // Standard markdown images: replace just the destination inside the
            // token, keeping alt text (and any title) verbatim.
            for image in collector.images {
                guard let uri = dataURIIfLocal(image.destination, baseURL: baseURL) else { continue }
                let token = (content as NSString).substring(with: image.tokenRange)
                // The destination is the last thing before the closing paren
                // (a ` "title"` may sit after it), so search backwards. If the
                // parsed destination doesn't appear verbatim (angle-bracket
                // destinations, unusual escapes), skip rather than guess.
                guard let r = token.range(of: image.destination, options: .backwards) else { continue }
                let destRange = NSRange(r, in: token)
                edits.append((NSRange(location: base + image.tokenRange.location + destRange.location,
                                      length: destRange.length), uri))
            }

            // Raw HTML <img> tags (inline or a whole HTML block): replace the
            // src attribute value only.
            for tag in collector.htmlTags {
                guard let uri = dataURIIfLocal(tag.src, baseURL: baseURL) else { continue }
                edits.append((NSRange(location: base + tag.srcRange.location,
                                      length: tag.srcRange.length), uri))
            }

            // Obsidian `![[image]]` embeds — a custom parse pass, not AST. Skip
            // spans that overlap inline code (parseWikiLinks only knows about
            // overlap with spans already collected, and we hand it none).
            if features.contains(.wikilinkEmbed) {
                var spans: [SyntaxHighlighter.Span] = []
                SyntaxHighlighter.parseWikiLinks(content, into: &spans, features: features)
                for span in spans {
                    guard case .image(let destination, _, _) = span.kind else { continue }
                    guard !collector.inlineCodeRanges.contains(where: {
                        NSIntersectionRange($0, span.fullRange).length > 0
                    }) else { continue }
                    guard let uri = dataURIIfLocal(destination, baseURL: baseURL) else { continue }
                    edits.append((NSRange(location: base + span.fullRange.location,
                                          length: span.fullRange.length), "![](\(uri))"))
                }
            }
        }

        let result = NSMutableString(string: markdown)
        for (range, text) in edits.sorted(by: { $0.0.location > $1.0.location }) {
            result.replaceCharacters(in: range, with: text)
        }
        return result as String
    }

    /// The data URI for a locally-resolvable image destination, or nil for
    /// remote/already-inlined sources, unresolvable paths, missing files, and
    /// files that don't decode as images — all of which pass through unchanged.
    private static func dataURIIfLocal(_ destination: String, baseURL: URL) -> String? {
        let dest = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dest.isEmpty, !LocalImageInlining.isRemoteOrInlined(dest),
              let url = LocalImageInlining.resolve(dest, baseURL: baseURL),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return LocalImageInlining.dataURI(url)
    }
}

// MARK: - InlineImageCollector

/// Walks one block's swift-markdown AST collecting markdown `Image` tokens,
/// `<img>` src values (from InlineHTML and HTMLBlock), and inline-code ranges
/// (used by the caller to reject false-positive `![[…]]` embeds inside code).
private struct InlineImageCollector: MarkupWalker {
    let source: String
    private let rangeConverter: SourceRangeConverter

    /// `![alt](dest)` tokens: the whole token's range plus the parsed destination.
    var images: [(tokenRange: NSRange, destination: String)] = []
    /// `<img>` src attribute values: the value's range (quotes excluded) + text.
    var htmlTags: [(srcRange: NSRange, src: String)] = []
    var inlineCodeRanges: [NSRange] = []

    init(source: String) {
        self.source = source
        self.rangeConverter = SourceRangeConverter(source: source)
    }

    mutating func visitImage(_ image: Image) {
        if let range = image.range {
            images.append((rangeConverter.nsRange(for: range), image.source ?? ""))
        }
        // No descendInto: alt-text children can't contain another image.
    }

    mutating func visitInlineCode(_ code: InlineCode) {
        if let range = code.range {
            inlineCodeRanges.append(rangeConverter.nsRange(for: range))
        }
    }

    mutating func visitInlineHTML(_ html: InlineHTML) {
        guard let range = html.range else { return }
        collectImgSrcs(from: html.rawHTML, base: rangeConverter.nsRange(for: range).location)
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        guard let range = html.range else { return }
        collectImgSrcs(from: html.rawHTML, base: rangeConverter.nsRange(for: range).location)
    }

    /// Finds every `<img … src="…">` in `html` and records the src *value's*
    /// range (so the caller can replace it without touching the rest of the tag).
    private mutating func collectImgSrcs(from html: String, base: Int) {
        guard let regex = try? NSRegularExpression(
            pattern: #"<img\b[^>]*?\bsrc\s*=\s*(?:"([^"]*)"|'([^']*)')"#,
            options: [.caseInsensitive]) else { return }
        let ns = html as NSString
        for m in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let valueRange = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2)
            guard valueRange.location != NSNotFound else { continue }
            htmlTags.append((NSRange(location: base + valueRange.location,
                                     length: valueRange.length),
                             ns.substring(with: valueRange)))
        }
    }
}

// MARK: - SourceRangeConverter

/// Converts swift-markdown `SourceRange`s (1-based line + UTF-8 *byte* column)
/// to UTF-16 `NSRange`s over the same source string — the same conversion
/// `SyntaxHighlighter.SpanCollector.nsRange(for:)` performs, factored for
/// non-styling use.
private struct SourceRangeConverter {
    let source: String
    /// UTF-8 byte offset where each 1-based line starts.
    let lineStartsUTF8: [Int]

    init(source: String) {
        self.source = source
        var starts = [0]
        var offset = 0
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            offset += line.utf8.count + 1
            starts.append(offset)
        }
        lineStartsUTF8 = starts
    }

    func utf16Offset(for location: SourceLocation) -> Int {
        let line = max(1, min(location.line, lineStartsUTF8.count))
        var byteOffset = lineStartsUTF8[line - 1] + (location.column - 1)
        let utf8 = source.utf8
        byteOffset = min(byteOffset, utf8.count)
        let idx8 = utf8.index(utf8.startIndex, offsetBy: byteOffset)
        guard let idx = String.Index(idx8, within: source) else {
            return (source as NSString).length
        }
        return source.utf16.distance(from: source.utf16.startIndex, to: idx)
    }

    func nsRange(for range: SourceRange) -> NSRange {
        let start = utf16Offset(for: range.lowerBound)
        let end = utf16Offset(for: range.upperBound)
        return NSRange(location: start, length: max(0, end - start))
    }
}
