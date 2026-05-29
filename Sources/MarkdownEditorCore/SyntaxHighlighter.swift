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
            case codeBlock(language: String?)
            case strikethrough
            case highlight
            case heading(Int)
            case link(destination: String)
            case image(destination: String)
            case blockquote
            case listItem(ordered: Bool, checkbox: CheckboxState? = nil)
            case table
            case thematicBreak
            case lineBreak

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

        // Trailing backslash line break (single-line blocks only).
        parseLineBreak(text, into: &walker.spans)

        // Deeply indented list items (4+ spaces) that swift-markdown treats as code.
        parseIndentedListItem(text, into: &walker.spans)

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

    /// Parses trailing `\` as a line break indicator.
    private static func parseLineBreak(_ text: String, into spans: inout [Span]) {
        let nsText = text as NSString
        let len = nsText.length
        guard len > 0 else { return }
        // Must not contain \n (only applies to single-line blocks)
        guard !text.contains("\n") else { return }
        let lastChar = nsText.character(at: len - 1)
        guard lastChar == 0x5C else { return }  // backslash
        // Not an escaped backslash (\\)
        if len >= 2 && nsText.character(at: len - 2) == 0x5C { return }
        let range = NSRange(location: len - 1, length: 1)
        spans.append(Span(
            kind: .lineBreak,
            fullRange: range,
            contentRange: NSRange(location: len - 1, length: 0),
            delimiterRanges: [range]
        ))
    }

    /// Detects list items with deep indentation (4+ spaces or tabs) that
    /// swift-markdown parses as indented code instead of list items.
    private static let indentedListRegex = try! NSRegularExpression(
        pattern: #"^([\t ]*\t[\t ]*|[ ]{4,})([-*+])\s"#
    )

    private static func parseIndentedListItem(_ text: String, into spans: inout [Span]) {
        // Only single-line blocks (no \n)
        guard !text.contains("\n") else { return }
        let nsText = text as NSString
        let match = indentedListRegex.firstMatch(
            in: text, range: NSRange(location: 0, length: nsText.length)
        )
        guard let match = match else { return }
        // Don't duplicate if swift-markdown already found a listItem
        let alreadyHasListItem = spans.contains {
            if case .listItem = $0.kind { return true }
            return false
        }
        guard !alreadyHasListItem else { return }

        let full = NSRange(location: 0, length: nsText.length)
        let delimEnd = match.range(at: 0).upperBound  // end of "    - "
        let delim = NSRange(location: 0, length: delimEnd)
        let content = NSRange(location: delimEnd, length: nsText.length - delimEnd)

        // Remove any codeBlock span swift-markdown created for this indented line
        spans.removeAll { span in
            if case .codeBlock = span.kind { return true }
            return false
        }

        spans.append(Span(
            kind: .listItem(ordered: false, checkbox: nil),
            fullRange: full,
            contentRange: content,
            delimiterRanges: [delim]
        ))

        // Re-parse the content for inline formatting (bold, italic, code, etc.)
        // since swift-markdown treated the whole line as code and skipped them.
        let contentStr = nsText.substring(with: content)
        let inlineSpans = parse(contentStr)
        for s in inlineSpans {
            // Skip any listItem spans from the recursive parse
            if case .listItem = s.kind { continue }
            // Offset ranges by the content start position
            let offsetFull = NSRange(location: s.fullRange.location + content.location,
                                     length: s.fullRange.length)
            let offsetContent = NSRange(location: s.contentRange.location + content.location,
                                        length: s.contentRange.length)
            let offsetDelims = s.delimiterRanges.map {
                NSRange(location: $0.location + content.location, length: $0.length)
            }
            spans.append(Span(kind: s.kind, fullRange: offsetFull,
                              contentRange: offsetContent,
                              delimiterRanges: offsetDelims))
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

        /// Trims delimiter ranges to the expected width for emphasis types.
        /// When cmark includes unmatched delimiter characters in the emphasis
        /// node's source range (e.g. `**here*` → italic with opening `**`),
        /// this trims them so only the real delimiter chars are styled.
        /// Returns adjusted (fullRange, delimiterRanges).
        func trimEmphasisDelimiters(
            expectedWidth: Int, full: NSRange, delims: [NSRange]
        ) -> (NSRange, [NSRange]) {
            guard delims.count == 2 else { return (full, delims) }
            var trimmedDelims = delims
            var trimmedFull = full

            // Opening delimiter: keep only the last `expectedWidth` chars
            if delims[0].length > expectedWidth {
                let excess = delims[0].length - expectedWidth
                trimmedDelims[0] = NSRange(location: delims[0].location + excess,
                                            length: expectedWidth)
                trimmedFull = NSRange(location: trimmedFull.location + excess,
                                      length: trimmedFull.length - excess)
            }

            // Closing delimiter: keep only the first `expectedWidth` chars
            if delims[1].length > expectedWidth {
                let excess = delims[1].length - expectedWidth
                trimmedDelims[1] = NSRange(location: delims[1].location,
                                            length: expectedWidth)
                trimmedFull = NSRange(location: trimmedFull.location,
                                      length: trimmedFull.length - excess)
            }

            return (trimmedFull, trimmedDelims)
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
                    let rawDelims = delimiterRanges(parent: full, children: strong.children)
                    let (trimmedFull, delims) = trimEmphasisDelimiters(
                        expectedWidth: 3, full: full, delims: rawDelims)
                    let content = contentRange(full: trimmedFull, delims: delims)
                    spans.append(Span(
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
            spans.append(Span(
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
                    spans.append(Span(
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
            spans.append(Span(
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

            spans.append(Span(
                kind: .code,
                fullRange: full,
                contentRange: content,
                delimiterRanges: [openDelim, closeDelim]
            ))
        }

        // MARK: - Code Blocks

        mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
            guard let range = codeBlock.range else { return }
            let full = nsRange(for: range)
            guard full.length > 0 else { return }

            let nsSource = source as NSString
            let blockText = nsSource.substring(with: full) as NSString
            var delims: [NSRange] = []
            var cStart = full.location
            var cEnd = full.upperBound

            let firstNL = blockText.range(of: "\n")
            if firstNL.location != NSNotFound {
                // Opening fence line (including newline)
                let openLen = firstNL.location + 1
                delims.append(NSRange(location: full.location, length: openLen))
                cStart = full.location + openLen

                // Look for closing fence line
                let lastNL = blockText.range(of: "\n", options: .backwards)
                if lastNL.location != NSNotFound && lastNL.location != firstNL.location {
                    let lastLineStart = lastNL.location + 1
                    if lastLineStart < blockText.length {
                        let lastLine = blockText.substring(from: lastLineStart)
                            .trimmingCharacters(in: .whitespaces)
                        if lastLine.hasPrefix("```") || lastLine.hasPrefix("~~~") {
                            let closeStart = full.location + lastNL.location
                            delims.append(NSRange(location: closeStart,
                                                  length: full.upperBound - closeStart))
                            cEnd = closeStart
                        }
                    }
                }
            } else {
                // Single line (shouldn't normally happen with fenced code blocks)
                delims.append(full)
                cStart = full.upperBound
            }

            let content = NSRange(location: cStart, length: max(0, cEnd - cStart))
            spans.append(Span(
                kind: .codeBlock(language: codeBlock.language),
                fullRange: full,
                contentRange: content,
                delimiterRanges: delims
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

        // MARK: - Images

        mutating func visitImage(_ image: Image) {
            guard let range = image.range else {
                descendInto(image)
                return
            }
            let full = nsRange(for: range)
            let delims = delimiterRanges(parent: full, children: image.children)
            let content = contentRange(full: full, delims: delims)

            spans.append(Span(
                kind: .image(destination: image.source ?? ""),
                fullRange: full,
                contentRange: content,
                delimiterRanges: delims
            ))
            descendInto(image)
        }

        // MARK: - Block Quotes

        mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
            guard let range = blockQuote.range else {
                descendInto(blockQuote)
                return
            }
            let full = nsRange(for: range)
            let nsSource = source as NSString

            // Scan each line within the blockquote for "> " prefixes
            var delims: [NSRange] = []
            var cursor = full.location
            while cursor < full.upperBound {
                // Find the end of this line
                let remaining = NSRange(location: cursor, length: full.upperBound - cursor)
                let nlRange = nsSource.range(of: "\n", options: [], range: remaining)
                let lineEnd = nlRange.location != NSNotFound ? nlRange.location : full.upperBound

                // Check if line starts with optional spaces then ">"
                let lineRange = NSRange(location: cursor, length: lineEnd - cursor)
                let line = nsSource.substring(with: lineRange)
                let stripped = line.drop(while: { $0 == " " })
                if stripped.first == ">" {
                    let prefixLen = line.count - stripped.count + 1  // spaces + ">"
                    let delimLen = prefixLen + (stripped.dropFirst().first == " " ? 1 : 0)  // include trailing space
                    delims.append(NSRange(location: cursor, length: delimLen))
                }

                cursor = nlRange.location != NSNotFound ? nlRange.location + 1 : full.upperBound
            }

            let content = contentRange(full: full, delims: delims)

            spans.append(Span(
                kind: .blockquote,
                fullRange: full,
                contentRange: content,
                delimiterRanges: delims
            ))
            descendInto(blockQuote)
        }

        // MARK: - Tables

        mutating func visitTable(_ table: Table) {
            guard let range = table.range else {
                descendInto(table)
                return
            }
            let full = nsRange(for: range)

            // Compute gaps between child rows (head/body) as delimiters
            // (this captures the separator row between head and body)
            var childRanges: [NSRange] = []
            for child in table.children {
                if let cr = child.range {
                    childRanges.append(nsRange(for: cr))
                }
            }

            var delims: [NSRange] = []
            if let first = childRanges.first, first.location > full.location {
                delims.append(NSRange(location: full.location,
                                      length: first.location - full.location))
            }
            for i in 0..<(childRanges.count - 1) {
                let gapStart = childRanges[i].upperBound
                let gapEnd = childRanges[i + 1].location
                if gapEnd > gapStart {
                    delims.append(NSRange(location: gapStart,
                                          length: gapEnd - gapStart))
                }
            }
            if let last = childRanges.last, last.upperBound < full.upperBound {
                delims.append(NSRange(location: last.upperBound,
                                      length: full.upperBound - last.upperBound))
            }

            spans.append(Span(
                kind: .table,
                fullRange: full,
                contentRange: full,
                delimiterRanges: delims
            ))
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
