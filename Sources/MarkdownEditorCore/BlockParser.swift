import Foundation

/// Splits a document string into `Block`s and preserves block identity
/// across re-parses so the "active block" doesn't jump around.
///
/// Strategy:
///   1. Split the raw string on single newlines (`\n`) to get paragraphs.
///   2. Compute each paragraph's `NSRange` within the full string.
///   3. Match new paragraphs to previous blocks by content equality to
///      preserve UUIDs.  Unmatched paragraphs get fresh UUIDs.
public enum BlockParser {

    public static func parse(_ text: String, previous: [Block] = []) -> [Block] {
        let nsText = text as NSString
        let paragraphs = splitParagraphs(text)

        var available = previous
        var blocks: [Block] = []
        var cursor = 0

        for para in paragraphs {
            let length = (para as NSString).length
            let range = NSRange(location: cursor, length: length)

            let id: UUID
            if let idx = available.firstIndex(where: { $0.content == para }) {
                id = available[idx].id
                available.remove(at: idx)
            } else {
                id = UUID()
            }

            blocks.append(Block(id: id, content: para, range: range))

            // Advance past this paragraph.
            cursor = range.upperBound
            // Skip the single \n separator (if present).
            if cursor < nsText.length && nsText.character(at: cursor) == UInt16(0x0A) {
                cursor += 1
            }
        }

        return blocks
    }

    // MARK: - Helpers

    /// Splits text into paragraphs on single newlines, merging table rows
    /// into single multi-line blocks.
    private static func splitParagraphs(_ text: String) -> [String] {
        if text.isEmpty { return [""] }

        let lines = text.components(separatedBy: "\n")
        var result: [String] = []
        var i = 0

        while i < lines.count {
            // Detect table: header row followed by separator row
            if i + 1 < lines.count && isTableRow(lines[i]) && isTableSeparator(lines[i + 1]) {
                var merged = [lines[i]]
                i += 1
                while i < lines.count && (isTableRow(lines[i]) || isTableSeparator(lines[i])) {
                    merged.append(lines[i])
                    i += 1
                }
                result.append(merged.joined(separator: "\n"))
                continue
            }

            result.append(lines[i])
            i += 1
        }

        return result
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
}
