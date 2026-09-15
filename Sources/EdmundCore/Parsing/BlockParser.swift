import Foundation
import Markdown

/// Splits a document string into `Block`s and preserves block identity
/// across re-parses so the "active block" doesn't jump around.
///
/// Strategy:
///   1. Split the raw string on single newlines (`\n`) to get paragraphs,
///      tagging each with its `BlockKind`.
///   2. Compute each paragraph's `NSRange` within the full string.
///   3. Preserve UUIDs positionally: blocks in the unchanged prefix and
///      suffix (by content equality from both ends) keep their previous IDs;
///      the changed window in between gets fresh ones. The window is also the
///      exact set of blocks whose styling may have changed — the dirty set
///      the recompose engine restyles.
public enum BlockParser {

    public static func parse(_ text: String, previous: [Block] = [],
                             features: MarkdownFeatures = .all) -> [Block] {
        parseWithDiff(text, previous: previous, features: features).blocks
    }

    /// Parses `text` and returns the blocks plus the changed window: the range
    /// of indices (in the new list) outside the unchanged prefix/suffix.
    public static func parseWithDiff(
        _ text: String, previous: [Block] = [], features: MarkdownFeatures = .all
    ) -> (blocks: [Block], changed: Range<Int>) {
        let nsText = text as NSString
        let paragraphs = splitParagraphs(text, features: features)

        var blocks: [Block] = []
        blocks.reserveCapacity(paragraphs.count)
        var cursor = 0

        for (para, kind) in paragraphs {
            let length = (para as NSString).length
            let range = NSRange(location: cursor, length: length)
            blocks.append(Block(content: para, range: range, kind: kind))

            // Advance past this paragraph.
            cursor = range.upperBound
            // Skip the single \n separator (if present).
            if cursor < nsText.length && nsText.character(at: cursor) == UInt16(0x0A) {
                cursor += 1
            }
        }

        let changed = assignIdentity(old: previous, new: &blocks)
        return (blocks, changed)
    }

    /// Re-parses only the lines affected by an edit, splicing the untouched
    /// prefix and (shifted) suffix of the previous parse around the re-split
    /// window — O(edit), not O(document).
    ///
    /// The window starts one block before the first affected block: every
    /// merge rule needs at most that much left context (quote-run adjacency,
    /// the indented-code prevLine check, and the table-separator /
    /// setext-underline lookaheads are single-step; an unclosed
    /// fence/math opener further up would already contain the edit inside its
    /// merged block). Downstream, the re-split continues until a produced
    /// block boundary lands on an old block start at/after the edit's end —
    /// from there the old parse is provably identical, because a block's
    /// parse depends only on its own and following lines.
    ///
    /// Returns nil when the inputs don't allow it (caller falls back to the
    /// full parse).
    public static func incrementalParse(
        text: String,
        old: [Block],
        editedOldRange: NSRange,
        delta: Int,
        features: MarkdownFeatures = .all
    ) -> (blocks: [Block], changed: Range<Int>)? {
        guard !old.isEmpty else { return nil }
        let newLength = (text as NSString).length
        let oldLength = newLength - delta
        guard editedOldRange.location >= 0,
              editedOldRange.upperBound <= oldLength else { return nil }

        // Front matter is anchored at the document start (`i == 0`) yet its
        // extent depends on a closing `---` that can sit anywhere below — so an
        // edit far from the top can form, dissolve, or resize it, which the
        // incremental splice can't track without stranding a stale block-0 kind.
        // Whenever front matter is in play (the doc now starts with a `---`
        // opener, or block 0 was front matter) fall back to the full parse. It's
        // cheap and rare — only documents that begin with `---`.
        if features.contains(.frontMatter),
           firstLine(of: text).trimmingCharacters(in: .whitespaces) == "---"
            || old.first?.kind == .frontMatter {
            return nil
        }

        guard let firstAffected = blockIndex(in: old, forOffset: editedOldRange.location)
        else { return nil }

        var windowStartIndex = max(0, firstAffected - 1)
        // A setext underline merges the whole run of single-line paragraph
        // blocks above it into one heading (consumeBlock's multi-line setext
        // scan), so the window must start before that entire run, not just
        // one block back — keep walking back while the block at the window
        // start is itself a `.paragraph` block. This is a superset of the
        // one-block-back rule above (a non-paragraph block one back leaves
        // the loop immediately), so every other merge rule stays covered.
        while windowStartIndex > 0, case .paragraph = old[windowStartIndex].kind {
            windowStartIndex -= 1
        }
        let windowStartOffset = old[windowStartIndex].range.location
        let editEndNew = editedOldRange.upperBound + delta

        var buf = LineBuffer(text, from: windowStartOffset)
        var window: [Block] = []
        var cursor = windowStartOffset   // new-coords offset of the next block
        var lineIndex = 0
        var suffixStart: Int? = nil      // old block index to splice from
        // Backward context for the indented-code rule. The block before the
        // window is untouched by the edit, so its old content is current.
        var prevLine: String? = windowStartIndex > 0
            ? lastLine(of: old[windowStartIndex - 1].content) : nil

        while true {
            // Resync probe at this block boundary (not at the initial one).
            if cursor > windowStartOffset && cursor >= editEndNew {
                let oldOffset = cursor - delta
                if let j = blockIndex(in: old, forOffset: oldOffset),
                   old[j].range.location == oldOffset,
                   oldOffset >= editedOldRange.upperBound {
                    // An indented-code-ish start depends on the line above it
                    // (blank vs not), which the edit may have changed — the
                    // old parse from here isn't provably identical. Bail to
                    // the full parse (rare and cheap).
                    if isIndentedCodeLine(firstLine(of: old[j].content)) { return nil }
                    // Same bail for HTML-block-ish starts: type 7 depends on the
                    // line above (which the edit may have changed), so an old
                    // block whose first line looks like ANY html-block opener
                    // isn't provably re-derivable — full parse (rare and cheap).
                    // prevLine: nil = most permissive check.
                    if htmlBlockStart(firstLine(of: old[j].content), prevLine: nil) != nil { return nil }
                    suffixStart = j
                    break
                }
            }

            guard let (content, kind, next) = consumeBlock(&buf, at: lineIndex,
                                                           prevLine: prevLine,
                                                           features: features) else {
                break   // end of document: the window runs to the end
            }
            let length = (content as NSString).length
            window.append(Block(content: content,
                                range: NSRange(location: cursor, length: length),
                                kind: kind))
            lineIndex = next
            prevLine = lastLine(of: content)
            cursor += length
            // Skip the `\n` separator if another line follows; otherwise this
            // was the document's final block — stop before re-probing (the
            // boundary we'd probe is the block we just consumed).
            if buf.line(at: next) != nil { cursor += 1 } else { break }
        }

        // Trim unchanged leading window blocks (the lookback block usually
        // re-parses identically): preserve their identity and styling, and
        // keep the changed window tight.
        let spliceLimit = suffixStart ?? old.count
        var keep = 0
        while keep < window.count, windowStartIndex + keep < spliceLimit,
              old[windowStartIndex + keep].content == window[keep].content {
            window[keep].id = old[windowStartIndex + keep].id
            window[keep].isStyled = old[windowStartIndex + keep].isStyled
            keep += 1
        }

        var blocks = Array(old[0..<windowStartIndex])
        blocks.append(contentsOf: window)
        if let s = suffixStart {
            for j in s..<old.count {
                var b = old[j]
                b.range.location += delta
                blocks.append(b)
            }
        }

        return (blocks, (windowStartIndex + keep) ..< (windowStartIndex + window.count))
    }

    /// Binary search over sorted, adjacent block ranges — the same
    /// inclusive-upper-bound semantics as the editor's lookup (an offset at a
    /// block's trailing separator maps to that block; past-end clamps to last).
    private static func blockIndex(in blocks: [Block], forOffset offset: Int) -> Int? {
        guard !blocks.isEmpty else { return nil }
        var lo = 0
        var hi = blocks.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if blocks[mid].range.upperBound < offset { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Positional prefix/suffix diff: scans content equality from the front
    /// and the back, copies old IDs onto the matches, and returns the changed
    /// window in new-list indices. O(unchanged + changed); never matches a
    /// block across the edit (no cross-document ID stealing).
    static func assignIdentity(old: [Block], new: inout [Block]) -> Range<Int> {
        var prefix = 0
        while prefix < old.count && prefix < new.count
            && old[prefix].content == new[prefix].content {
            new[prefix].id = old[prefix].id
            new[prefix].isStyled = old[prefix].isStyled
            prefix += 1
        }

        var suffix = 0
        let maxSuffix = min(old.count, new.count) - prefix  // overlap clamp
        while suffix < maxSuffix
            && old[old.count - 1 - suffix].content == new[new.count - 1 - suffix].content {
            new[new.count - 1 - suffix].id = old[old.count - 1 - suffix].id
            new[new.count - 1 - suffix].isStyled = old[old.count - 1 - suffix].isStyled
            suffix += 1
        }

        return prefix ..< (new.count - suffix)
    }

    // MARK: - Helpers

    /// Lazily materializes the `\n`-separated line segments of a text starting
    /// at a given UTF-16 offset. `components(separatedBy: "\n")` semantics:
    /// number of segments = number of newlines + 1, so a trailing `\n` yields
    /// a final empty segment. Both the full and incremental parses consume
    /// lines through this buffer, so they cannot diverge.
    struct LineBuffer {
        private let ns: NSString
        private(set) var lines: [String] = []
        private var nextOffset: Int
        private var exhausted = false
        /// Setext-scan memo: a failed underline scan that terminated at line
        /// `k` proves no scan starting before `k` can find an underline (the
        /// intervening lines are all plain paragraphs and `k` isn't an
        /// underline), so `consumeBlock` skips the scan for start lines below
        /// this bound. Without it, a long blank-line-free paragraph run makes
        /// the parse quadratic (each line re-scans to the run's end).
        var noSetextUnderlineBefore = 0

        init(_ text: String, from offset: Int = 0) {
            self.ns = text as NSString
            self.nextOffset = offset
        }

        /// The line at index `i` (buffer-relative), fetching as needed.
        /// Returns nil past the end of the text.
        mutating func line(at i: Int) -> String? {
            while lines.count <= i && !exhausted {
                fetchNext()
            }
            return i < lines.count ? lines[i] : nil
        }

        private mutating func fetchNext() {
            guard !exhausted else { return }
            let remaining = NSRange(location: nextOffset, length: ns.length - nextOffset)
            let nl = ns.range(of: "\n", options: [], range: remaining)
            if nl.location == NSNotFound {
                lines.append(ns.substring(with: remaining))
                exhausted = true
            } else {
                lines.append(ns.substring(
                    with: NSRange(location: nextOffset, length: nl.location - nextOffset)))
                nextOffset = nl.upperBound
                if nextOffset == ns.length {
                    // Trailing newline: one final empty segment.
                    lines.append("")
                    exhausted = true
                }
            }
        }
    }

    /// Consumes one block starting at line `i`, merging multi-line constructs
    /// (fences, display math, quote runs, tables, indented code runs, setext
    /// headings). `prevLine` is the last line before `i` (nil at document
    /// start) — the only backward context any rule uses: an indented code
    /// block may start only after a blank line. Returns the block's
    /// content/kind and the index of the line after it.
    static func consumeBlock(_ buf: inout LineBuffer, at i: Int, prevLine: String?,
                             features: MarkdownFeatures = .all)
        -> (content: String, kind: BlockKind, next: Int)? {
        guard let first = buf.line(at: i) else { return nil }

        // YAML front matter: a `---`…`---` fence pair at the very start of the
        // document (`i == 0 && prevLine == nil` is the doc start in both the
        // full and incremental parse paths). Checked before the setext and
        // thematic-break classification below so a leading `---` opens front
        // matter instead of becoming a rule. Requires a *closing* `---`, so a
        // lone `---` (or `---` followed by non-front-matter) falls through to a
        // thematic break.
        if features.contains(.frontMatter), i == 0, prevLine == nil,
           first.trimmingCharacters(in: .whitespaces) == "---" {
            var merged = [first]
            var j = i + 1
            var closed = false
            while let line = buf.line(at: j) {
                merged.append(line)
                j += 1
                if line.trimmingCharacters(in: .whitespaces) == "---" { closed = true; break }
            }
            if closed {
                return (merged.joined(separator: "\n"), .frontMatter, j)
            }
            // No closing fence: not front matter — fall through to normal handling.
        }

        // Detect opening code fence
        if let fence = codeFenceInfo(first) {
            var merged = [first]
            var j = i + 1
            while let line = buf.line(at: j) {
                merged.append(line)
                j += 1
                if isClosingFence(line, char: fence.char, count: fence.count) {
                    break
                }
            }
            return (merged.joined(separator: "\n"), .fence, j)
        }

        // Detect display-math fence: a line starting with `$$`.
        if let closedOnSameLine = displayMathClosedOnSameLine(first) {
            if closedOnSameLine {
                return (first, .mathDisplay, i + 1)
            }
            var merged = [first]
            var j = i + 1
            while let line = buf.line(at: j) {
                merged.append(line)
                j += 1
                if line.contains("$$") { break }
            }
            return (merged.joined(separator: "\n"), .mathDisplay, j)
        }

        // A list item whose content is a `$$…$$` display block: the opener sits
        // after the marker (`1. $$…`) and the closer is on a later line. Because
        // BlockParser splits one block per list line, the opener and closer would
        // otherwise land in different blocks and the display-math span could never
        // form. Merge forward to the closing `$$` and emit one `.listItem` block —
        // `parseDisplayMath` allows newlines inside `$$`, so the span forms and the
        // renderer promotes it to a block (read mode gets this for free via
        // swift-markdown's lazy continuation). Forward-only, like the fence merge
        // above, so the incremental-reparse invariant holds.
        if isListLine(first), displayMathClosedOnSameLine(contentAfterListMarker(first)) == false {
            var merged = [first]
            var j = i + 1
            while let line = buf.line(at: j) {
                merged.append(line)
                j += 1
                if line.contains("$$") { break }
            }
            return (merged.joined(separator: "\n"), .listItem, j)
        }

        // Obsidian multi-line `%%…%%` comment: a line that starts with `%%` and
        // is not closed by a second `%%` on the same line opens a comment that
        // spans following blocks. Merge forward to the line that closes it.
        // A single-line `%%x%%` closes on its own line and is left to the inline
        // `.comment` pass. Placed after the fence/math branches (which may hold
        // a literal `%%`) and before the quote/paragraph handling.
        if features.contains(.multiBlockComment),
           let closedOnSameLine = multiBlockCommentOpener(first), !closedOnSameLine {
            var merged = [first]
            var j = i + 1
            while let line = buf.line(at: j) {
                merged.append(line)
                j += 1
                if line.contains("%%") { break }
            }
            return (merged.joined(separator: "\n"), .multiBlockComment, j)
        }

        // Merge block-quote lines into one block (the editor's styling /
        // activation unit per quote).
        if isBlockquoteLine(first) {
            // Callouts stay strict: only consecutive `>` lines. Lazy
            // continuation is deliberately suppressed so a following `> [!type]`
            // can't be pulled into a prior callout's paragraph (GFM ex. 228).
            // Read mode matches this (HTMLRenderer.renderCallout splits at the
            // first non-`>` line).
            if quoteRunOpensCallout(first) {
                var merged = [first]
                var j = i + 1
                while let line = buf.line(at: j), isBlockquoteLine(line) {
                    merged.append(line)
                    j += 1
                }
                return (merged.joined(separator: "\n"), .quoteRun(isCallout: true), j)
            }
            // Plain block quote: honor CommonMark lazy continuation (a bare
            // non-blank line after a quote paragraph joins the quote). The
            // extent depends only on this line and following lines up to the
            // next blank (a blank always ends a quote), so the parse stays
            // forward-only and the incremental invariant holds.
            if let (content, next) = mergePlainQuote(&buf, at: i) {
                return (content, .quoteRun(isCallout: false), next)
            }
            // Fallback (candidate's first child wasn't a BlockQuote — shouldn't
            // happen): strict `>`-run.
            var merged = [first]
            var j = i + 1
            while let line = buf.line(at: j), isBlockquoteLine(line) {
                merged.append(line)
                j += 1
            }
            return (merged.joined(separator: "\n"), .quoteRun(isCallout: false), j)
        }

        // Detect table: header row followed by separator row with the same
        // cell count (GFM: a mismatched delimiter row isn't a table at all).
        if isTableRow(first), let second = buf.line(at: i + 1), isTableSeparator(second),
           splitTableRow(first).count == splitTableRow(second).count {
            var merged = [first]
            var j = i + 1
            while let line = buf.line(at: j), isTableRow(line) || isTableSeparator(line) {
                merged.append(line)
                j += 1
            }
            return (merged.joined(separator: "\n"), .table, j)
        }

        // Indented code block (GFM): a run of lines indented 4+ spaces (or a
        // tab), starting only after a blank line / document start so list
        // continuation text isn't swallowed. Deeply indented list items keep
        // priority (the indentedListRegex rescue — deliberate divergence).
        // Interior blank lines belong to the block (GFM Examples 82/87); a
        // run of blanks only ends the block if code doesn't resume after
        // them — trailing blanks stay separate `.blank` blocks.
        if isIndentedCodeLine(first), prevLine == nil || isBlankLine(prevLine!) {
            var merged = [first]
            var j = i + 1
            while let line = buf.line(at: j) {
                if isIndentedCodeLine(line) {
                    merged.append(line)
                    j += 1
                    continue
                }
                guard isBlankLine(line) else { break }
                var k = j
                while let blank = buf.line(at: k), isBlankLine(blank) { k += 1 }
                guard let resumed = buf.line(at: k), isIndentedCodeLine(resumed) else { break }
                for m in j..<k { merged.append(buf.line(at: m)!) }
                j = k
            }
            return (merged.joined(separator: "\n"), .indentedCode, j)
        }

        // GFM §4.6 HTML block. Types 1–5 scan forward for the end-condition line
        // (included; the end may already be on the start line; unterminated runs
        // to EOF — spec: end of document closes it). Types 6/7 end BEFORE the
        // first blank line (the blank stays its own `.blank` block). Type 7
        // can't interrupt a paragraph — htmlBlockStart gates it on prevLine.
        // Placement: after indented code (the ≤3-space guard keeps a 4-space-
        // indented `<div>` as indented code); a `<`-line forming a valid table
        // header+separator still becomes a table (deliberate divergence, tables
        // win — this branch sits below the table branch); must precede the
        // setext scan so an HTML start isn't swallowed as heading content.
        // Edit mode shows the block as colored SOURCE (read mode renders it) —
        // same split as GitHub's editor; rendered HTML in edit mode is
        // impossible under the storage==rawSource invariant.
        if let type = htmlBlockStart(first, prevLine: prevLine) {
            var merged = [first]
            var j = i + 1
            switch type {
            case .scriptPreStyle, .comment, .processing, .declaration, .cdata:
                if !htmlBlockEnds(first, type: type) {
                    while let line = buf.line(at: j) {
                        merged.append(line)
                        j += 1
                        if htmlBlockEnds(line, type: type) { break }
                    }
                }
            case .blockTag, .completeTag:
                while let line = buf.line(at: j), !isBlankLine(line) {
                    merged.append(line)
                    j += 1
                }
            }
            return (merged.joined(separator: "\n"), .htmlBlock, j)
        }

        // Setext heading: a paragraph line underlined by `===` (h1) or `---`
        // (h2). Consuming the underline here means a `---` after a paragraph
        // is a heading underline (GFM setext wins over thematic break); only
        // a `---` after a blank line / non-paragraph stays a rule.
        //
        // The underline can follow any number of plain paragraph lines, not
        // just the first (GFM Example 51: "Foo\nbar\n---" is one heading
        // whose content is "Foo\nbar") — so scan forward through a run of
        // paragraph lines looking for the underline, checking each line for
        // a setext underline *before* classifying it (an underline reads as
        // `.paragraph`/`.thematicBreak` under `classifyLine`, and must
        // terminate-and-merge the run rather than continue or break it). A
        // table start also breaks the run, mirroring the table branch above
        // so a table isn't swallowed as heading content. If no underline is
        // found, fall through and return just `first` as a single-line
        // paragraph block — Edmund deliberately keeps one block per
        // paragraph line when there's no setext underline beneath it.
        if case .paragraph = classifyLine(first), i >= buf.noSetextUnderlineBefore {
            var j = i + 1
            while let line = buf.line(at: j) {
                if let level = setextUnderlineLevel(line) {
                    let merged = (i...j).map { buf.line(at: $0)! }
                    return (merged.joined(separator: "\n"), .heading(level: level), j + 1)
                }
                guard case .paragraph = classifyLine(line) else { break }
                if isTableRow(line), let next = buf.line(at: j + 1), isTableSeparator(next),
                   splitTableRow(line).count == splitTableRow(next).count {
                    break
                }
                // An HTML block start (types 1–6 interrupt paragraphs; type 7 is
                // gated on the previous line) terminates the run, mirroring the
                // table break above — otherwise "Foo\n<div>\n---" would merge
                // into a setext heading instead of paragraph + HTML block
                // (GFM: the `---` belongs to the HTML block).
                if htmlBlockStart(line, prevLine: buf.line(at: j - 1)) != nil { break }
                j += 1
            }
            // No underline: everything up to the terminator at `j` is plain
            // paragraph lines, so no scan starting before `j` can succeed.
            buf.noSetextUnderlineBefore = j
        }

        return (first, classifyLine(first), i + 1)
    }

    /// Splits text into paragraphs on single newlines, merging fenced code blocks
    /// and table rows into single multi-line blocks. Each paragraph is tagged
    /// with its `BlockKind`.
    private static func splitParagraphs(_ text: String,
                                        features: MarkdownFeatures = .all)
        -> [(content: String, kind: BlockKind)] {
        if text.isEmpty { return [("", .blank)] }

        var buf = LineBuffer(text)
        var result: [(content: String, kind: BlockKind)] = []
        var i = 0
        var prevLine: String? = nil
        while let (content, kind, next) = consumeBlock(&buf, at: i, prevLine: prevLine,
                                                       features: features) {
            result.append((content, kind))
            i = next
            prevLine = lastLine(of: content)
        }
        return result
    }

    /// The text after the last `\n` (the whole string when single-line) —
    /// the `prevLine` context for the block that follows.
    private static func lastLine(of content: String) -> String {
        if let nl = content.range(of: "\n", options: .backwards) {
            return String(content[nl.upperBound...])
        }
        return content
    }

    /// The text before the first `\n` (the whole string when single-line).
    private static func firstLine(of content: String) -> String {
        if let nl = content.range(of: "\n") {
            return String(content[..<nl.lowerBound])
        }
        return content
    }

    // MARK: - Line Classification

    /// Classifies a single (non-merged) line. Advisory: see `BlockKind`.
    private static func classifyLine(_ line: String) -> BlockKind {
        if line.allSatisfy({ $0 == " " || $0 == "\t" }) { return .blank }
        let trimmed = line.drop(while: { $0 == " " })
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        if (1...6).contains(hashes),
           trimmed.count == hashes || trimmed.dropFirst(hashes).first == " " {
            return .heading(level: hashes)
        }
        if isThematicBreakLine(line) { return .thematicBreak }
        if isListLine(line) { return .listItem }
        return .paragraph
    }

    /// Returns true if the line is a bullet (`- `, `* `, `+ `) or ordered
    /// (`1. `, `1) `) list item, with any leading-space indent.
    static func isListLine(_ line: String) -> Bool {
        let trimmed = line.drop(while: { $0 == " " })
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            return true
        }
        let digits = trimmed.prefix(while: { $0.isNumber })
        guard !digits.isEmpty else { return false }
        let rest = trimmed.dropFirst(digits.count)
        return rest.hasPrefix(". ") || rest.hasPrefix(") ")
    }

    /// The content of a list line after its bullet/ordered marker and the single
    /// following space. Returns the whole line unchanged if it isn't a list line.
    /// Used to test whether a list item's content opens display math.
    static func contentAfterListMarker(_ line: String) -> String {
        let trimmed = line.drop(while: { $0 == " " })
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            return String(trimmed.dropFirst(2))
        }
        let digits = trimmed.prefix(while: { $0.isNumber })
        guard !digits.isEmpty else { return line }
        let rest = trimmed.dropFirst(digits.count)
        if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
            return String(rest.dropFirst(2))
        }
        return line
    }

    /// True if `s` is a list line whose entire content after the marker is blank
    /// — i.e. the marker alone. Lets the renderer treat a leading list marker as
    /// "the block is owned by what follows" (e.g. a `$$…$$` display block).
    static func isListMarkerOnly(_ s: String) -> Bool {
        isListLine(s) && contentAfterListMarker(s).allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// Returns the heading level if the line is a setext underline: ≤3 leading
    /// spaces, then **3 or more** of the same character (`=` → level 1, `-` →
    /// level 2), then only trailing spaces/tabs. Internal spaces (`- - -`)
    /// disqualify it, so a spaced thematic break after a paragraph stays a rule.
    ///
    /// Three is a deliberate divergence from CommonMark, which underlines on a
    /// single `-`/`=`: a lone dash or two under a line turned it into a heading
    /// by accident far more often than anyone wanted a one-dash underline. A
    /// heading (setext or thematic break) now needs a run of three, matching
    /// the `---`/`===`/`***` the eye already reads as one.
    private static func setextUnderlineLevel(_ line: String) -> Int? {
        let trimmed = line.drop(while: { $0 == " " })
        guard line.count - trimmed.count <= 3,
              let first = trimmed.first, first == "=" || first == "-" else { return nil }
        let run = trimmed.prefix(while: { $0 == first })
        guard run.count >= 3,
              trimmed.dropFirst(run.count).allSatisfy({ $0 == " " || $0 == "\t" }) else { return nil }
        return first == "=" ? 1 : 2
    }

    /// Returns true if the line opens/continues an indented code block: some
    /// content indented by ≥4 spaces or a tab, that isn't a deeply indented
    /// list item (the indentedListRegex rescue keeps priority).
    static func isIndentedCodeLine(_ line: String) -> Bool {
        guard !isBlankLine(line) else { return false }
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
        guard indent.contains("\t") || indent.count >= 4 else { return false }
        let range = NSRange(location: 0, length: (line as NSString).length)
        return SyntaxHighlighter.indentedListRegex.firstMatch(in: line, range: range) == nil
    }

    private static func isBlankLine(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// GFM §4.6 HTML block start conditions.
    enum HTMLBlockType {
        case scriptPreStyle   // 1: <script|<pre|<style  — ends ON the line containing </script>|</pre>|</style>
        case comment          // 2: <!--                 — ends ON the line containing -->
        case processing       // 3: <?                   — ends ON the line containing ?>
        case declaration      // 4: <! + ASCII uppercase — ends ON the line containing >
        case cdata            // 5: <![CDATA[            — ends ON the line containing ]]>
        case blockTag         // 6: one of the 62 block tag names — ends BEFORE a blank line
        case completeTag      // 7: a complete lone tag  — ends BEFORE a blank line; can't interrupt a paragraph
    }

    // Tag set pinned to CommonMark 0.29 / GFM (script|pre|style — no textarea,
    // which later CommonMark added); deliberate, documented in ARCHITECTURE §10.
    private static let htmlType1Regex = try! NSRegularExpression(
        pattern: #"^ {0,3}<(?:script|pre|style)(?:[ \t>]|$)"#, options: [.caseInsensitive])

    private static let htmlType6Regex = try! NSRegularExpression(
        pattern: #"^ {0,3}</?(?:address|article|aside|base|basefont|blockquote|body|caption|center|col|colgroup|dd|details|dialog|dir|div|dl|dt|fieldset|figcaption|figure|footer|form|frame|frameset|h1|h2|h3|h4|h5|h6|head|header|hr|html|iframe|legend|li|link|main|menu|menuitem|nav|noframes|ol|optgroup|option|p|param|section|source|summary|table|tbody|td|tfoot|th|thead|title|tr|track|ul)(?:[ \t]|/?>|$)"#,
        options: [.caseInsensitive])

    /// One COMPLETE open tag (full §6.10 attribute grammar — quoted values may
    /// contain `>`) or closing tag, alone on the line. Check order 1→7 means a
    /// normal `<script …>` is always claimed by type 1 first; the one leak is a
    /// self-closing `<script/>` lone tag, which spec calls a paragraph but we
    /// call type 7 — deliberate, harmless divergence (ARCHITECTURE §10).
    private static let htmlType7Regex = try! NSRegularExpression(
        pattern: #"^ {0,3}(?:<[A-Za-z][A-Za-z0-9-]*(?:\s+[a-zA-Z_:][a-zA-Z0-9:._-]*(?:\s*=\s*(?:[^\s"'=<>`]+|'[^']*'|"[^"]*"))?)*\s*/?>|</[A-Za-z][A-Za-z0-9-]*\s*>)[ \t]*$"#)

    /// GFM §4.6: the HTML-block type `line` opens, or nil. `prevLine` gates type 7
    /// (it cannot interrupt a paragraph — same backward context as indented code).
    /// O(line), and only `<`-prefixed lines get past the cheap guard.
    static func htmlBlockStart(_ line: String, prevLine: String?) -> HTMLBlockType? {
        let trimmed = line.drop(while: { $0 == " " })
        guard line.count - trimmed.count <= 3, trimmed.first == "<" else { return nil }
        let range = NSRange(location: 0, length: (line as NSString).length)
        if htmlType1Regex.firstMatch(in: line, range: range) != nil { return .scriptPreStyle }
        if trimmed.hasPrefix("<!--") { return .comment }
        if trimmed.hasPrefix("<?") { return .processing }
        if trimmed.hasPrefix("<![CDATA[") { return .cdata }
        if trimmed.hasPrefix("<!"), let c = trimmed.dropFirst(2).first,
           c.isASCII, c.isUppercase { return .declaration }
        if htmlType6Regex.firstMatch(in: line, range: range) != nil { return .blockTag }
        if prevLine == nil || isBlankLine(prevLine!),
           htmlType7Regex.firstMatch(in: line, range: range) != nil { return .completeTag }
        return nil
    }

    /// End condition for types 1–5 (the matching line is INCLUDED in the block).
    private static func htmlBlockEnds(_ line: String, type: HTMLBlockType) -> Bool {
        switch type {
        case .scriptPreStyle:
            let l = line.lowercased()
            return l.contains("</script>") || l.contains("</pre>") || l.contains("</style>")
        case .comment:     return line.contains("-->")
        case .processing:  return line.contains("?>")
        case .declaration: return line.contains(">")
        case .cdata:       return line.contains("]]>")
        case .blockTag, .completeTag: return false
        }
    }

    /// Returns true for a thematic break: 3+ of the same `-`/`*`/`_` character
    /// and nothing else but spaces.
    private static func isThematicBreakLine(_ line: String) -> Bool {
        let stripped = line.filter { $0 != " " && $0 != "\t" }
        guard stripped.count >= 3, let first = stripped.first,
              first == "-" || first == "*" || first == "_" else { return false }
        return stripped.allSatisfy { $0 == first }
    }

    /// Returns true if the first line of a quote run opens a callout
    /// (`> [!type]`, known or unknown type).
    private static func quoteRunOpensCallout(_ firstLine: String) -> Bool {
        let trimmed = firstLine.drop(while: { $0 == " " })
        guard trimmed.first == ">" else { return false }
        return Callout.parseMarker(String(trimmed.dropFirst())) != nil
    }

    /// If the line (after optional leading whitespace) starts with `$$`, returns
    /// whether a second `$$` also appears on the same line (a one-line `$$…$$`
    /// block). Returns nil when the line is not a display-math opener.
    private static func displayMathClosedOnSameLine(_ line: String) -> Bool? {
        let trimmed = line.drop(while: { $0 == " " })
        guard trimmed.hasPrefix("$$") else { return nil }
        return trimmed.dropFirst(2).contains("$$")
    }

    /// If the line (after optional leading whitespace) starts with `%%`, returns
    /// whether a second `%%` also appears on the same line (a one-line `%%…%%`
    /// comment, left to the inline pass). Returns nil when the line is not a
    /// `%%` opener.
    private static func multiBlockCommentOpener(_ line: String) -> Bool? {
        let trimmed = line.drop(while: { $0 == " " })
        guard trimmed.hasPrefix("%%") else { return nil }
        return trimmed.dropFirst(2).contains("%%")
    }

    /// Returns true if the line is a block-quote line (optional leading spaces
    /// then `>`).
    private static func isBlockquoteLine(_ line: String) -> Bool {
        return line.drop(while: { $0 == " " }).first == ">"
    }

    /// Extent of a plain block quote starting at line `i`, honoring CommonMark
    /// lazy continuation. Gathers the run of non-blank candidate lines (a blank
    /// always ends a quote), parses them with swift-markdown, and truncates the
    /// quote to the first `BlockQuote` node's line span — so the exact rules
    /// (heading/list/fence/thematic-break interrupt; an empty `>` closes the
    /// paragraph; a bare paragraph line continues it) come straight from the
    /// CommonMark parser, matching read mode. Returns the quote content and the
    /// index of the line after it, or nil when the candidate's first child
    /// isn't a BlockQuote (caller falls back to the strict `>`-run).
    private static func mergePlainQuote(_ buf: inout LineBuffer, at i: Int)
        -> (content: String, next: Int)? {
        var candidate: [String] = []
        var j = i
        while let line = buf.line(at: j), !isBlankLine(line) {
            candidate.append(line)
            j += 1
        }
        let doc = Document(parsing: candidate.joined(separator: "\n"),
                           options: [.disableSmartOpts])
        guard doc.child(at: 0) is BlockQuote else { return nil }
        // The candidate has no blank lines, so its top-level blocks are
        // contiguous: the quote spans lines 1 ..< (second child's start line).
        // swift-markdown line numbers are 1-based within the candidate, and
        // candidate line 1 == buffer line `i`.
        let quoteLineCount: Int
        if doc.childCount > 1, let nextStart = doc.child(at: 1)?.range?.lowerBound.line {
            quoteLineCount = min(max(nextStart - 1, 1), candidate.count)
        } else {
            quoteLineCount = candidate.count
        }
        let content = candidate[0..<quoteLineCount].joined(separator: "\n")
        return (content, i + quoteLineCount)
    }

    /// Returns true if the line contains a pipe character (potential table row).
    private static func isTableRow(_ line: String) -> Bool {
        return line.contains("|")
    }

    /// Returns true if the line is a table separator (e.g., "| --- | --- |").
    ///
    /// A cell may use any number of dashes, not only three: `- | -` and
    /// `:--:|--` are separators too, per GFM (each column is `:?-+:?`).
    /// Requiring literal `---` misread a single-dash separator as a bullet
    /// list — its leading `- ` looked like a list marker.
    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|"), trimmed.contains("-"),
              trimmed.allSatisfy({ "|:- \t".contains($0) }) else { return false }
        // Every cell between the pipes must be a valid delimiter. Outer pipes
        // leave empty leading/trailing parts, which are dropped.
        let cells = trimmed.split(separator: "|", omittingEmptySubsequences: true)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { isDelimiterCell($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// A single separator cell: an optional leading colon, one or more dashes,
    /// an optional trailing colon, and nothing else.
    private static func isDelimiterCell(_ cell: String) -> Bool {
        var rest = Substring(cell)
        if rest.first == ":" { rest = rest.dropFirst() }
        let dashes = rest.prefix(while: { $0 == "-" })
        guard !dashes.isEmpty else { return false }
        rest = rest.dropFirst(dashes.count)
        if rest.first == ":" { rest = rest.dropFirst() }
        return rest.isEmpty
    }

    /// Returns fence info (character and count) if the line is an opening code fence.
    private static func codeFenceInfo(_ line: String) -> (char: Character, count: Int)? {
        let trimmed = line.drop(while: { $0 == " " })
        let leadingSpaces = line.count - trimmed.count
        guard leadingSpaces <= 3 else { return nil }
        guard let first = trimmed.first, (first == "`" || first == "~") else { return nil }
        let count = trimmed.prefix(while: { $0 == first }).count
        guard count >= 3 else { return nil }
        if first == "`" {
            let afterFence = trimmed.dropFirst(count)
            if afterFence.contains("`") { return nil }
        }
        return (first, count)
    }

    /// Returns true if the line is a valid closing fence for the given char/count.
    private static func isClosingFence(_ line: String, char: Character, count: Int) -> Bool {
        let trimmed = line.drop(while: { $0 == " " })
        let leadingSpaces = line.count - trimmed.count
        guard leadingSpaces <= 3 else { return false }
        guard let first = trimmed.first, first == char else { return false }
        let fenceCount = trimmed.prefix(while: { $0 == char }).count
        guard fenceCount >= count else { return false }
        let after = trimmed.dropFirst(fenceCount)
        return after.allSatisfy { $0 == " " || $0 == "\t" }
    }
}
