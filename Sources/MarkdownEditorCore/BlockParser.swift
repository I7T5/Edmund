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

    /// Positional prefix/suffix diff: scans content equality from the front
    /// and the back, copies old IDs onto the matches, and returns the changed
    /// window in new-list indices. O(unchanged + changed); never matches a
    /// block across the edit (no cross-document ID stealing).
    static func assignIdentity(old: [Block], new: inout [Block]) -> Range<Int> {
        var prefix = 0
        while prefix < old.count && prefix < new.count
            && old[prefix].content == new[prefix].content {
            new[prefix].id = old[prefix].id
            prefix += 1
        }

        var suffix = 0
        let maxSuffix = min(old.count, new.count) - prefix  // overlap clamp
        while suffix < maxSuffix
            && old[old.count - 1 - suffix].content == new[new.count - 1 - suffix].content {
            new[new.count - 1 - suffix].id = old[old.count - 1 - suffix].id
            suffix += 1
        }

        return prefix ..< (new.count - suffix)
    }

    // MARK: - Helpers

    /// Splits text into paragraphs on single newlines, merging fenced code blocks
    /// and table rows into single multi-line blocks. Each paragraph is tagged
    /// with its `BlockKind`.
    private static func splitParagraphs(_ text: String) -> [(content: String, kind: BlockKind)] {
        if text.isEmpty { return [("", .blank)] }

        let lines = text.components(separatedBy: "\n")
        var result: [(content: String, kind: BlockKind)] = []
        var i = 0

        while i < lines.count {
            // Detect opening code fence
            if let fence = codeFenceInfo(lines[i]) {
                var merged = [lines[i]]
                i += 1
                while i < lines.count {
                    let line = lines[i]
                    merged.append(line)
                    i += 1
                    if isClosingFence(line, char: fence.char, count: fence.count) {
                        break
                    }
                }
                result.append((merged.joined(separator: "\n"), .fence))
                continue
            }

            // Detect display-math fence: a line starting with `$$`.
            if let closedOnSameLine = displayMathClosedOnSameLine(lines[i]) {
                if closedOnSameLine {
                    result.append((lines[i], .mathDisplay))
                    i += 1
                    continue
                }
                var merged = [lines[i]]
                i += 1
                while i < lines.count {
                    merged.append(lines[i])
                    let closes = lines[i].contains("$$")
                    i += 1
                    if closes { break }
                }
                result.append((merged.joined(separator: "\n"), .mathDisplay))
                continue
            }

            // Merge a run of consecutive block-quote lines (`>`) into one block.
            // This covers callouts and plain multi-line block quotes alike. It is
            // also required for editing: each block becomes a single NSTextBlock
            // (one "table cell"), and NSTextView refuses to delete at the boundary
            // between two adjacent cells — so per-line block-quote cells made the
            // marker characters undeletable. One cell per quote avoids that.
            if isBlockquoteLine(lines[i]) {
                let isCallout = quoteRunOpensCallout(lines[i])
                var merged = [lines[i]]
                i += 1
                while i < lines.count && isBlockquoteLine(lines[i]) {
                    merged.append(lines[i])
                    i += 1
                }
                result.append((merged.joined(separator: "\n"), .quoteRun(isCallout: isCallout)))
                continue
            }

            // Detect table: header row followed by separator row
            if i + 1 < lines.count && isTableRow(lines[i]) && isTableSeparator(lines[i + 1]) {
                var merged = [lines[i]]
                i += 1
                while i < lines.count && (isTableRow(lines[i]) || isTableSeparator(lines[i])) {
                    merged.append(lines[i])
                    i += 1
                }
                result.append((merged.joined(separator: "\n"), .table))
                continue
            }

            result.append((lines[i], classifyLine(lines[i])))
            i += 1
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
