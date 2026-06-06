import Foundation
import Markdown

// MARK: - Custom Parsers
//
// Regex / scan-based passes for inline constructs that swift-markdown does not
// model. Each appends to the span list built by the AST walker (see parse()):
//
//   - parseHighlight        ==text==
//   - parseDisplayMath       $$\u{2026}$$ (block pre-merged by BlockParser)
//   - parseMath              $\u{2026}$ (Pandoc-style disambiguation)
//   - parseLineBreak         trailing backslash hard break
//   - parseIndentedListItem  4+ space list items swift-markdown treats as code

extension SyntaxHighlighter {

    /// Parses ==highlight== spans using regex (not supported by swift-markdown).
    static func parseHighlight(_ text: String, into spans: inout [Span]) {
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

    /// Recognizes a whole block as `$$…$$` display math. `BlockParser` has
    /// already merged a multi-line `$$ … $$` run into a single block, so here we
    /// only need to confirm the block opens and closes with `$$`.
    static func parseDisplayMath(_ text: String, into spans: inout [Span]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$"), trimmed.count >= 4 else { return }

        let ns = text as NSString
        let open = ns.range(of: "$$")
        let close = ns.range(of: "$$", options: .backwards)
        guard open.location != NSNotFound, close.location != NSNotFound,
              close.location >= open.location + 2 else { return }

        let full = NSRange(location: open.location, length: close.upperBound - open.location)
        let content = NSRange(location: open.upperBound, length: close.location - open.upperBound)
        spans.append(Span(
            kind: .math(display: true),
            fullRange: full,
            contentRange: content,
            delimiterRanges: [open, close]
        ))
    }

    /// Scans for inline `$…$` math. Uses Pandoc-style disambiguation so prose
    /// like "it cost $5 to $10" is left alone:
    ///   - the opening `$` is immediately followed by a non-space, non-`$` char,
    ///   - the closing `$` is immediately preceded by a non-space char and is
    ///     not followed by a digit,
    ///   - `\$` is a literal escape, `$$` is skipped (display math, later phase),
    ///   - inline math never spans a newline.
    static func parseMath(_ text: String, into spans: inout [Span]) {
        let ns = text as NSString
        let n = ns.length
        let dollar: unichar = 0x24, backslash: unichar = 0x5C, newline: unichar = 0x0A

        func isSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 }
        func isDigit(_ c: unichar) -> Bool { c >= 0x30 && c <= 0x39 }

        var i = 0
        while i < n {
            let c = ns.character(at: i)
            if c == backslash { i += 2; continue }   // skip escaped char
            if c != dollar { i += 1; continue }
            // Skip display `$$` (handled per-block in a later phase).
            if i + 1 < n && ns.character(at: i + 1) == dollar { i += 2; continue }
            // Opening `$`: must be followed by a non-space, non-`$` character.
            guard i + 1 < n else { break }
            let next = ns.character(at: i + 1)
            if isSpace(next) || next == dollar || next == newline { i += 1; continue }

            // Find the closing `$`.
            var j = i + 1
            var close = -1
            while j < n {
                let cj = ns.character(at: j)
                if cj == backslash { j += 2; continue }
                if cj == newline { break }           // inline math stays on one line
                if cj == dollar {
                    let prev = ns.character(at: j - 1)
                    let isDouble = j + 1 < n && ns.character(at: j + 1) == dollar
                    let nextIsDigit = j + 1 < n && isDigit(ns.character(at: j + 1))
                    if !isDouble && !isSpace(prev) && !nextIsDigit { close = j; break }
                }
                j += 1
            }

            guard close > i + 1 else { i += 1; continue }

            let full = NSRange(location: i, length: close - i + 1)
            // Don't match inside code spans or a display-math block.
            let overlaps = spans.contains { existing in
                switch existing.kind {
                case .code, .codeBlock, .math(display: true):
                    return existing.fullRange.location <= full.location
                        && existing.fullRange.upperBound >= full.upperBound
                default:
                    return false
                }
            }
            if !overlaps {
                spans.append(Span(
                    kind: .math(display: false),
                    fullRange: full,
                    contentRange: NSRange(location: i + 1, length: close - i - 1),
                    delimiterRanges: [NSRange(location: i, length: 1),
                                      NSRange(location: close, length: 1)]
                ))
            }
            i = close + 1
        }
    }

    /// Parses trailing `\` as a line break indicator.
    static func parseLineBreak(_ text: String, into spans: inout [Span]) {
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
    /// swift-markdown parses as indented code instead of list items. Group 2 is
    /// the marker — an unordered bullet (`-`/`*`/`+`) or an ordered number
    /// (`1.`/`1)`), so nested ordered lists are rescued too.
    static let indentedListRegex = try! NSRegularExpression(
        pattern: #"^([\t ]*\t[\t ]*|[ ]{4,})([-*+]|\d{1,9}[.)])\s"#
    )

    /// Matches a GFM task-list checkbox at the start of list-item content:
    /// "[ ] ", "[x] ", or "[X] ". Capture group 1 is the state character.
    static let checkboxRegex = try! NSRegularExpression(
        pattern: #"^\[([ xX])\]\s"#
    )

    static func parseIndentedListItem(_ text: String, into spans: inout [Span]) {
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
        let markerEnd = match.range(at: 0).upperBound  // end of "    - "

        // An ordered marker (1./1)) starts with a digit; a bullet (-/*/+) doesn't.
        let marker = nsText.substring(with: match.range(at: 2))
        let ordered = marker.first?.isNumber ?? false

        // Detect a GFM task-list checkbox following the marker ("[ ] "/"[x] ").
        // swift-markdown skips these on deeply-indented lines (it treats the
        // whole line as code), so we parse the checkbox ourselves — otherwise
        // task items nested beyond level 2 render without a circle. Only the
        // unordered `- [ ]` form is supported.
        var checkbox: Span.Kind.CheckboxState? = nil
        var delimEnd = markerEnd
        if !ordered {
            let afterMarker = nsText.substring(from: markerEnd) as NSString
            if let cb = checkboxRegex.firstMatch(
                in: afterMarker as String,
                range: NSRange(location: 0, length: afterMarker.length)
            ) {
                let stateChar = afterMarker.substring(with: cb.range(at: 1))
                checkbox = (stateChar == "x" || stateChar == "X") ? .checked : .unchecked
                delimEnd = markerEnd + cb.range(at: 0).length
            }
        }

        let delim = NSRange(location: 0, length: delimEnd)
        let content = NSRange(location: delimEnd, length: nsText.length - delimEnd)

        // Remove any codeBlock span swift-markdown created for this indented line
        spans.removeAll { span in
            if case .codeBlock = span.kind { return true }
            return false
        }

        spans.append(Span(
            kind: .listItem(ordered: ordered, checkbox: checkbox),
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
}
