import Foundation

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

    public static func parse(_ text: String, previous: [Block] = []) -> [Block] {
        parseWithDiff(text, previous: previous).blocks
    }

    /// Parses `text` and returns the blocks plus the changed window: the range
    /// of indices (in the new list) outside the unchanged prefix/suffix.
    public static func parseWithDiff(
        _ text: String, previous: [Block] = []
    ) -> (blocks: [Block], changed: Range<Int>) {
        let nsText = text as NSString
        let paragraphs = splitParagraphs(text)

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
    /// merge rule needs at most that much left context (quote-run adjacency
    /// and the table header+separator lookahead are single-step; an unclosed
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
        delta: Int
    ) -> (blocks: [Block], changed: Range<Int>)? {
        guard !old.isEmpty else { return nil }
        let newLength = (text as NSString).length
        let oldLength = newLength - delta
        guard editedOldRange.location >= 0,
              editedOldRange.upperBound <= oldLength else { return nil }

        guard let firstAffected = blockIndex(in: old, forOffset: editedOldRange.location)
        else { return nil }

        let windowStartIndex = max(0, firstAffected - 1)
        let windowStartOffset = old[windowStartIndex].range.location
        let editEndNew = editedOldRange.upperBound + delta

        var buf = LineBuffer(text, from: windowStartOffset)
        var window: [Block] = []
        var cursor = windowStartOffset   // new-coords offset of the next block
        var lineIndex = 0
        var suffixStart: Int? = nil      // old block index to splice from

        while true {
            // Resync probe at this block boundary (not at the initial one).
            if cursor > windowStartOffset && cursor >= editEndNew {
                let oldOffset = cursor - delta
                if let j = blockIndex(in: old, forOffset: oldOffset),
                   old[j].range.location == oldOffset,
                   oldOffset >= editedOldRange.upperBound {
                    suffixStart = j
                    break
                }
            }

            guard let (content, kind, next) = consumeBlock(&buf, at: lineIndex) else {
                break   // end of document: the window runs to the end
            }
            let length = (content as NSString).length
            window.append(Block(content: content,
                                range: NSRange(location: cursor, length: length),
                                kind: kind))
            lineIndex = next
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
    /// (fences, display math, quote runs, tables). Returns the block's
    /// content/kind and the index of the line after it.
    static func consumeBlock(_ buf: inout LineBuffer, at i: Int)
        -> (content: String, kind: BlockKind, next: Int)? {
        guard let first = buf.line(at: i) else { return nil }

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

        // Merge a run of consecutive block-quote lines (`>`) into one block.
        // This covers callouts and plain multi-line block quotes alike, and
        // gives the editor one styling/activation unit per quote.
        if isBlockquoteLine(first) {
            let isCallout = quoteRunOpensCallout(first)
            var merged = [first]
            var j = i + 1
            while let line = buf.line(at: j), isBlockquoteLine(line) {
                merged.append(line)
                j += 1
            }
            return (merged.joined(separator: "\n"), .quoteRun(isCallout: isCallout), j)
        }

        // Detect table: header row followed by separator row
        if isTableRow(first), let second = buf.line(at: i + 1), isTableSeparator(second) {
            var merged = [first]
            var j = i + 1
            while let line = buf.line(at: j), isTableRow(line) || isTableSeparator(line) {
                merged.append(line)
                j += 1
            }
            return (merged.joined(separator: "\n"), .table, j)
        }

        return (first, classifyLine(first), i + 1)
    }

    /// Splits text into paragraphs on single newlines, merging fenced code blocks
    /// and table rows into single multi-line blocks. Each paragraph is tagged
    /// with its `BlockKind`.
    private static func splitParagraphs(_ text: String) -> [(content: String, kind: BlockKind)] {
        if text.isEmpty { return [("", .blank)] }

        var buf = LineBuffer(text)
        var result: [(content: String, kind: BlockKind)] = []
        var i = 0
        while let (content, kind, next) = consumeBlock(&buf, at: i) {
            result.append((content, kind))
            i = next
        }
        return result
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

    /// Returns true if the line is a block-quote line (optional leading spaces
    /// then `>`).
    private static func isBlockquoteLine(_ line: String) -> Bool {
        return line.drop(while: { $0 == " " }).first == ">"
    }

    /// Returns true if the line contains a pipe character (potential table row).
    private static func isTableRow(_ line: String) -> Bool {
        return line.contains("|")
    }

    /// Returns true if the line is a table separator (e.g., "| --- | --- |").
    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") && trimmed.contains("---") else { return false }
        return trimmed.allSatisfy { "|:- \t".contains($0) }
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
