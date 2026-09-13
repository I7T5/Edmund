import AppKit

// MARK: - Pasting a list into a list
//
// Text copied out of another list carries its own markers, and pasted into a
// list item verbatim it reads `- - one` or turns a checklist into bullets.
// When the caret is in a list item and the clipboard's first line is itself a
// list line, every pasted marker is rewritten to the target list's family —
// its bullet, `- [ ]` for a checklist (a pasted `[x]` keeps its tick), `1.`
// for a numbered list (renumbering settles the sequence) — and re-indented
// relative to the target item, so nested items stay nested.
//
// Pasted right after the marker of an empty item (Return just made it), the
// first pasted item takes over that line; anywhere else the pasted items
// start on a new line below.
//
// The adjusted text goes through `insertText`, so the paste takes the normal
// edit pipeline: one undo step, and the ordered-list renumbering in
// `didChangeText`.

extension EditorTextView {

    /// The clipboard's plain text rewritten for the list the caret is in, or
    /// nil when the ordinary paste is the right one.
    func listAdjustedPasteText(from pasteboard: NSPasteboard = .general) -> String? {
        guard let pasted = pasteboard.string(forType: .string),
              !rawTableEditing,
              let block = blockIndexForRawOffset(selectedRange().location),
              block < blocks.count, blocks[block].kind == .listItem
        else { return nil }
        let caretInLine = selectedRange().location - blocks[block].range.location
        return ListPaste.adjust(pasted, targetLine: blocks[block].content, caretInLine: caretInLine)
    }
}

/// The rewrite itself, on strings, so it can be tested without a pasteboard.
@MainActor
enum ListPaste {

    struct Line {
        let indent: String
        /// `- `, `* `, `3. `, `- [x] ` — as written, trailing space included.
        let marker: String
        let content: String

        var isTask: Bool { marker.contains("[") }
        var isOrdered: Bool { marker.first?.isNumber ?? false }
        var isChecked: Bool { marker.lowercased().contains("[x]") }
    }

    /// Splits a list line into indent, marker and content; nil for any other line.
    static func parse(_ line: String) -> Line? {
        let ns = line as NSString
        guard let m = EditorTextView.listMarkerRegex.firstMatch(
            in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return Line(indent: ns.substring(with: m.range(at: 1)),
                    marker: ns.substring(with: m.range(at: 2)),
                    content: ns.substring(from: m.range.upperBound))
    }

    /// `pasted` rewritten for the list `targetLine` belongs to, or nil when
    /// either side is not a list (the ordinary paste applies).
    static func adjust(_ pasted: String, targetLine: String, caretInLine: Int) -> String? {
        guard let target = parse(targetLine) else { return nil }
        let lines = pasted.components(separatedBy: "\n")
        guard let first = lines.first.flatMap({ parse($0) }) else { return nil }
        let afterMarker = caretInLine == ((target.indent + target.marker) as NSString).length

        var out: [String] = []
        for (i, raw) in lines.enumerated() {
            guard let line = parse(raw) else { out.append(raw); continue }
            // Nesting is relative to the first pasted item, whatever absolute
            // indent the source used.
            let relative = String(line.indent.dropFirst(first.indent.count))
            let prefix = i == 0 && afterMarker
                ? "" : target.indent + relative + marker(for: line, in: target)
            out.append(prefix + line.content)
        }
        let joined = out.joined(separator: "\n")
        // ponytail: pasting mid-content splits the item at the caret; the
        // pasted items go below it and the rest of the line trails the last.
        return afterMarker ? joined : "\n" + joined
    }

    /// The target family's marker for one pasted line.
    private static func marker(for line: Line, in target: Line) -> String {
        if target.isOrdered { return "1. " }
        let bullet = target.marker.prefix(1)
        if target.isTask { return bullet + (line.isChecked ? " [x] " : " [ ] ") }
        return bullet + " "
    }
}
