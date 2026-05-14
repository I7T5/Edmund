import Foundation
import Markdown

/// Parses raw markdown using Apple's swift-markdown (cmark-gfm) and returns
/// spans identifying inline formatting with their delimiter and content ranges.
///
/// This ensures the active block's syntax highlighting is consistent with the
/// rendered (non-active) blocks, including mismatched-delimiter edge cases
/// like `**hi*` (treated as literal `*` + italic `hi`).
public enum SyntaxHighlighter {

    // MARK: - Model

    public struct Span: Sendable {
        public let kind: Kind
        public let fullRange: NSRange
        public let contentRange: NSRange
        public let delimiterRanges: [NSRange]

        public enum Kind: Equatable, Sendable {
            case bold
            case italic
            case boldItalic
            case code
            case strikethrough
            case highlight
            case heading(Int)
            case link(destination: String)
            case blockquote
            case listItem(ordered: Bool, checkbox: CheckboxState? = nil)
            case thematicBreak

            public enum CheckboxState: Equatable, Sendable {
                case checked, unchecked
            }
        }
    }

    // MARK: - Parsing

    /// Returns all inline syntax spans found in `text`, ordered by position.
    public static func parse(_ text: String) -> [Span] {
        guard !text.isEmpty else { return [] }

        let doc = Document(parsing: text, options: [.disableSmartOpts])
        var walker = SpanCollector(source: text)
        walker.visit(doc)

        // ==highlight== is not supported by swift-markdown; parse with regex.
        parseHighlight(text, into: &walker.spans)

        return walker.spans.sorted { $0.fullRange.location < $1.fullRange.location }
    }

    // MARK: - Custom Parsers

    /// Parses ==highlight== spans using regex (not supported by swift-markdown).
    private static func parseHighlight(_ text: String, into spans: inout [Span]) {
        let nsText = text as NSString
        guard let regex = try? NSRegularExpression(pattern: "==(.+?)==", options: []) else { return }
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        for match in matches {
            let full = match.range(at: 0)
            let content = match.range(at: 1)
            // Skip if overlapping with a code span
            let overlaps = spans.contains { existing in
                existing.kind == .code &&
                existing.fullRange.location <= full.location &&
                existing.fullRange.upperBound >= full.upperBound
            }
            guard !overlaps else { continue }
            let openDelim = NSRange(location: full.location, length: 2)
            let closeDelim = NSRange(location: full.upperBound - 2, length: 2)
            spans.append(Span(
                kind: .highlight,
                fullRange: full,
                contentRange: content,
                delimiterRanges: [openDelim, closeDelim]
            ))
        }
    }

    // MARK: - AST Walker

    private struct SpanCollector: MarkupWalker {
        let source: String
        private let lines: [String]
        var spans: [Span] = []

        /// Track nesting depth so we can detect bold-inside-italic (= boldItalic)
        /// and avoid emitting duplicate spans.
        private var insideEmphasis = false
        private var insideStrong = false
        private var insideOrderedList = false

        init(source: String) {
            self.source = source
            self.lines = source.components(separatedBy: "\n")
        }

        // MARK: - Source offset conversion

        /// Converts a SourceLocation (1-indexed line, 1-indexed UTF-8 column)
        /// to a UTF-16 offset suitable for NSRange.
        func utf16Offset(for loc: SourceLocation) -> Int {
            var utf8Offset = 0
            for i in 0..<(loc.line - 1) {
                if i < lines.count {
                    utf8Offset += lines[i].utf8.count + 1
                }
            }
            utf8Offset += loc.column - 1

            let utf8View = source.utf8
            let targetIdx = utf8View.index(utf8View.startIndex,
                                           offsetBy: min(utf8Offset, utf8View.count))
            return source.utf16.distance(
                from: source.utf16.startIndex,
                to: String.Index(targetIdx, within: source.utf16) ?? source.utf16.endIndex
            )
        }

        func nsRange(for range: SourceRange) -> NSRange {
            let start = utf16Offset(for: range.lowerBound)
            let end = utf16Offset(for: range.upperBound)
            return NSRange(location: start, length: max(0, end - start))
        }

        /// Computes delimiter ranges by subtracting direct child ranges from parent.
        func delimiterRanges(parent: NSRange, children: some Sequence<Markup>) -> [NSRange] {
            // Collect child ranges (only direct children with source ranges)
            var childRanges: [NSRange] = []
            for child in children {
                if let cr = child.range {
                    childRanges.append(nsRange(for: cr))
                }
            }
            guard !childRanges.isEmpty else { return [] }

            var delims: [NSRange] = []
            let firstChild = childRanges[0]
            if firstChild.location > parent.location {
                delims.append(NSRange(location: parent.location,
                                      length: firstChild.location - parent.location))
            }
            let lastChild = childRanges[childRanges.count - 1]
            if lastChild.upperBound < parent.upperBound {
                delims.append(NSRange(location: lastChild.upperBound,
                                      length: parent.upperBound - lastChild.upperBound))
            }
            return delims
        }

        /// Compute content range from full range and delimiter ranges.
        func contentRange(full: NSRange, delims: [NSRange]) -> NSRange {
            var start = full.location
            var end = full.upperBound
            if let first = delims.first, first.location == full.location {
                start = first.upperBound
            }
            if let last = delims.last, last.upperBound == full.upperBound {
                end = last.location
            }
            return NSRange(location: start, length: max(0, end - start))
        }

        // MARK: - Visitors

        mutating func visitHeading(_ heading: Heading) {
            guard let range = heading.range else { return }
            let full = nsRange(for: range)
            let delimLen = heading.level + 1
            let cStart = full.location + delimLen
            let cLen = max(0, full.length - delimLen)

            spans.append(Span(
                kind: .heading(heading.level),
                fullRange: full,
                contentRange: NSRange(location: cStart, length: cLen),
                delimiterRanges: [NSRange(location: full.location, length: delimLen)]
            ))
            // Don't descend — heading subsumes children
        }

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
                    let delims = delimiterRanges(parent: full, children: strong.children)
                    let content = contentRange(full: full, delims: delims)
                    spans.append(Span(
                        kind: .boldItalic,
                        fullRange: full,
                        contentRange: content,
                        delimiterRanges: delims
                    ))
                    // Don't descend — we've handled the whole subtree
                    return
                }
            }

            // Regular italic
            let delims = delimiterRanges(parent: full, children: emphasis.children)
            let content = contentRange(full: full, delims: delims)
            spans.append(Span(
                kind: .italic,
                fullRange: full,
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
                    let delims = delimiterRanges(parent: full, children: emph.children)
                    let content = contentRange(full: full, delims: delims)
                    spans.append(Span(
                        kind: .boldItalic,
                        fullRange: full,
                        contentRange: content,
                        delimiterRanges: delims
                    ))
                    return
                }
            }

            // Regular bold
            let delims = delimiterRanges(parent: full, children: strong.children)
            let content = contentRange(full: full, delims: delims)
            spans.append(Span(
                kind: .bold,
                fullRange: full,
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

            spans.append(Span(
                kind: .code,
                fullRange: full,
                contentRange: content,
                delimiterRanges: [openDelim, closeDelim]
            ))
        }

        // MARK: - Strikethrough

        mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
            guard let range = strikethrough.range else {
                descendInto(strikethrough)
                return
            }
            let full = nsRange(for: range)
            let delims = delimiterRanges(parent: full, children: strikethrough.children)
            let content = contentRange(full: full, delims: delims)

            spans.append(Span(
                kind: .strikethrough,
                fullRange: full,
                contentRange: content,
                delimiterRanges: delims
            ))
            descendInto(strikethrough)
        }

        // MARK: - Links

        mutating func visitLink(_ link: Link) {
            guard let range = link.range else {
                descendInto(link)
                return
            }
            let full = nsRange(for: range)
            let delims = delimiterRanges(parent: full, children: link.children)
            let content = contentRange(full: full, delims: delims)

            spans.append(Span(
                kind: .link(destination: link.destination ?? ""),
                fullRange: full,
                contentRange: content,
                delimiterRanges: delims
            ))
            descendInto(link)
        }

        // MARK: - Block Quotes

        mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
            guard let range = blockQuote.range else {
                descendInto(blockQuote)
                return
            }
            let full = nsRange(for: range)
            let delims = delimiterRanges(parent: full, children: blockQuote.children)
            let content = contentRange(full: full, delims: delims)

            spans.append(Span(
                kind: .blockquote,
                fullRange: full,
                contentRange: content,
                delimiterRanges: delims
            ))
            descendInto(blockQuote)
        }

        // MARK: - Lists

        mutating func visitOrderedList(_ orderedList: OrderedList) {
            insideOrderedList = true
            descendInto(orderedList)
            insideOrderedList = false
        }

        mutating func visitListItem(_ listItem: ListItem) {
            guard let range = listItem.range else {
                descendInto(listItem)
                return
            }
            let full = nsRange(for: range)
            let delims = delimiterRanges(parent: full, children: listItem.children)
            let content = contentRange(full: full, delims: delims)

            let checkbox: Span.Kind.CheckboxState?
            if let cb = listItem.checkbox {
                checkbox = cb == .checked ? .checked : .unchecked
            } else {
                checkbox = nil
            }

            spans.append(Span(
                kind: .listItem(ordered: insideOrderedList, checkbox: checkbox),
                fullRange: full,
                contentRange: content,
                delimiterRanges: delims
            ))
            descendInto(listItem)
        }

        // MARK: - Thematic Break

        mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
            guard let range = thematicBreak.range else { return }
            let full = nsRange(for: range)

            spans.append(Span(
                kind: .thematicBreak,
                fullRange: full,
                contentRange: full,
                delimiterRanges: [full]
            ))
        }
    }
}
