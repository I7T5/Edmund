import Foundation
import Markdown

// Inline-construct visitors for SpanCollector: emphasis/strong (including the
// `***boldItalic***` nesting both cmark orderings produce), inline code,
// strikethrough, links, and images. The struct, its stored state, and the
// shared source-offset/delimiter helpers live in SyntaxHighlighter+Walker;
// block-level visitors (headings, code blocks, quotes, tables, lists) stay there
// too.
extension SyntaxHighlighter.SpanCollector {

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        guard let range = emphasis.range else {
            descendInto(emphasis)
            return
        }
        let full = nsRange(for: range)

        if insideStrong {
            // Already inside Strong — parent will have emitted boldItalic
            // or we're a nested emphasis. Just descend.
            descendInto(emphasis)
            return
        }

        // Check for ***...***: Emphasis wrapping a single Strong child
        // with the same source range.
        if emphasis.childCount == 1,
           let strong = emphasis.children.first(where: { $0 is Strong }) as? Strong,
           let strongRange = strong.range {
            let strongNS = nsRange(for: strongRange)
            if strongNS == full {
                // This is boldItalic. Compute delimiters from the Strong's children
                // (the text nodes inside), not from the Emphasis's children (the Strong).
                let rawDelims = delimiterRanges(parent: full, children: strong.children)
                let (trimmedFull, delims) = trimEmphasisDelimiters(
                    expectedWidth: 3, full: full, delims: rawDelims)
                let content = contentRange(full: trimmedFull, delims: delims)
                spans.append(SyntaxHighlighter.Span(
                    kind: .boldItalic,
                    fullRange: trimmedFull,
                    contentRange: content,
                    delimiterRanges: delims
                ))
                // Don't descend — we've handled the whole subtree
                return
            }
        }

        // Regular italic
        let rawDelims = delimiterRanges(parent: full, children: emphasis.children)
        let (trimmedFull, delims) = trimEmphasisDelimiters(
            expectedWidth: 1, full: full, delims: rawDelims)
        let content = contentRange(full: trimmedFull, delims: delims)
        spans.append(SyntaxHighlighter.Span(
            kind: .italic,
            fullRange: trimmedFull,
            contentRange: content,
            delimiterRanges: delims
        ))

        insideEmphasis = true
        descendInto(emphasis)
        insideEmphasis = false
    }

    mutating func visitStrong(_ strong: Strong) {
        guard let range = strong.range else {
            descendInto(strong)
            return
        }
        let full = nsRange(for: range)

        if insideEmphasis {
            // Already inside Emphasis — parent will have emitted boldItalic
            // or we're nested. Just descend.
            descendInto(strong)
            return
        }

        // Check for ***...***: Strong wrapping a single Emphasis child
        // with the same source range. (cmark can produce either nesting order.)
        if strong.childCount == 1,
           let emph = strong.children.first(where: { $0 is Emphasis }) as? Emphasis,
           let emphRange = emph.range {
            let emphNS = nsRange(for: emphRange)
            if emphNS == full {
                let rawDelims = delimiterRanges(parent: full, children: emph.children)
                let (trimmedFull, delims) = trimEmphasisDelimiters(
                    expectedWidth: 3, full: full, delims: rawDelims)
                let content = contentRange(full: trimmedFull, delims: delims)
                spans.append(SyntaxHighlighter.Span(
                    kind: .boldItalic,
                    fullRange: trimmedFull,
                    contentRange: content,
                    delimiterRanges: delims
                ))
                return
            }
        }

        // Regular bold
        let rawDelims = delimiterRanges(parent: full, children: strong.children)
        let (trimmedFull, delims) = trimEmphasisDelimiters(
            expectedWidth: 2, full: full, delims: rawDelims)
        let content = contentRange(full: trimmedFull, delims: delims)
        spans.append(SyntaxHighlighter.Span(
            kind: .bold,
            fullRange: trimmedFull,
            contentRange: content,
            delimiterRanges: delims
        ))

        insideStrong = true
        descendInto(strong)
        insideStrong = false
    }

    mutating func visitInlineCode(_ code: InlineCode) {
        guard let range = code.range else { return }
        let full = nsRange(for: range)
        guard full.length >= 2 else { return }

        let openDelim = NSRange(location: full.location, length: 1)
        let closeDelim = NSRange(location: full.upperBound - 1, length: 1)
        let content = NSRange(location: full.location + 1,
                              length: max(0, full.length - 2))

        spans.append(SyntaxHighlighter.Span(
            kind: .code,
            fullRange: full,
            contentRange: content,
            delimiterRanges: [openDelim, closeDelim]
        ))
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
        guard let range = strikethrough.range else {
            descendInto(strikethrough)
            return
        }
        let full = nsRange(for: range)
        let delims = delimiterRanges(parent: full, children: strikethrough.children)
        let content = contentRange(full: full, delims: delims)

        spans.append(SyntaxHighlighter.Span(
            kind: .strikethrough,
            fullRange: full,
            contentRange: content,
            delimiterRanges: delims
        ))
        descendInto(strikethrough)
    }

    mutating func visitLink(_ link: Link) {
        guard let range = link.range else {
            descendInto(link)
            return
        }
        let full = nsRange(for: range)
        let delims = delimiterRanges(parent: full, children: link.children)
        let content = contentRange(full: full, delims: delims)

        spans.append(SyntaxHighlighter.Span(
            kind: .link(destination: link.destination ?? ""),
            fullRange: full,
            contentRange: content,
            delimiterRanges: delims
        ))
        descendInto(link)
    }

    mutating func visitImage(_ image: Image) {
        guard let range = image.range else {
            descendInto(image)
            return
        }
        let full = nsRange(for: range)
        let delims = delimiterRanges(parent: full, children: image.children)
        let content = contentRange(full: full, delims: delims)

        spans.append(SyntaxHighlighter.Span(
            kind: .image(destination: image.source ?? ""),
            fullRange: full,
            contentRange: content,
            delimiterRanges: delims
        ))
        descendInto(image)
    }
}
