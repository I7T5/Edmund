import Foundation
import Markdown

// MARK: - AST Walker
//
// SpanCollector walks the swift-markdown AST and records a Span for each inline
// construct it recognizes (headings, emphasis, code, links, tables, lists, …),
// translating swift-markdown SourceRanges into NSRanges over the original text.
// Constructs swift-markdown does not model (==highlight==, $math$, indented
// list items) are handled by the regex passes in +CustomParsers.

extension SyntaxHighlighter {

    struct SpanCollector: MarkupWalker {
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
            var delims = delimiterRanges(parent: full, children: listItem.children)
            // An empty list item (just "- " / "1. " / "- [ ] " with no content,
            // e.g. a marker freshly created by pressing Return) has no child
            // nodes, so `delimiterRanges` finds no marker and the whole item is
            // treated as content. That collapses the marker's width to zero and
            // pushes the freshly-typed marker a full slot too deep. Synthesize
            // the marker delimiter from the leading text so the content begins
            // after it, matching a non-empty item.
            if delims.isEmpty, let markerLen = Self.leadingListMarkerLength(in: source, range: full) {
                delims = [NSRange(location: full.location, length: markerLen)]
            }
            let content = contentRange(full: full, delims: delims)

            // swift-markdown flags an item as a task list item via `checkbox`,
            // but it reports the STATE by scanning the whole line for `[x]` — so
            // an unchecked `- [ ]` whose body merely contains `[x]` (e.g. in a
            // code span) is wrongly reported as checked. Take only the "is this a
            // task item" signal from swift-markdown and read the actual state
            // from the leading `[ ]`/`[x]` marker ourselves.
            let checkbox: Span.Kind.CheckboxState?
            if listItem.checkbox != nil {
                let markerLen = max(0, content.location - full.location)
                let marker = (source as NSString).substring(
                    with: NSRange(location: full.location, length: markerLen))
                checkbox = Self.leadingCheckboxState(inMarker: marker)
                    ?? (listItem.checkbox == .checked ? .checked : .unchecked)
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

        /// Matches a list item's leading marker (optional indentation +
        /// `-`/`*`/`+` or `N.`, plus an optional `[ ]`/`[x]` checkbox), used to
        /// recover the marker range for an empty item that has no child nodes.
        private static let listMarkerRegex = try! NSRegularExpression(
            pattern: #"^[ \t]*(?:[-*+][ \t]+(?:\[[ xX]\][ \t]*)?|\d+\.[ \t]+)"#)

        /// Length (UTF-16) of the leading list marker within `range` of `source`,
        /// or nil if the text there doesn't begin with a marker.
        private static func leadingListMarkerLength(in source: String, range: NSRange) -> Int? {
            let line = (source as NSString).substring(with: range)
            let m = listMarkerRegex.firstMatch(
                in: line, range: NSRange(location: 0, length: (line as NSString).length))
            guard let m, m.range.location == 0, m.range.length > 0 else { return nil }
            return m.range.length
        }

        /// Reads a task-list checkbox state from the item's leading marker text
        /// (e.g. `"- [ ] "` → unchecked, `"1. [x] "` → checked) by inspecting the
        /// character inside the first `[...]`. Returns nil if no bracket is found.
        private static func leadingCheckboxState(inMarker marker: String)
            -> Span.Kind.CheckboxState? {
            let ns = marker as NSString
            let open = ns.range(of: "[")
            guard open.location != NSNotFound, open.upperBound < ns.length else { return nil }
            switch ns.substring(with: NSRange(location: open.upperBound, length: 1)) {
            case "x", "X": return .checked
            case " ":      return .unchecked
            default:       return nil
            }
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
