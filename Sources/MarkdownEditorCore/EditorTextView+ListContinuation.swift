import AppKit

// MARK: - List Continuation on Enter

extension EditorTextView {

    /// Regex that captures a list marker prefix:
    /// Group 1 = leading whitespace, Group 2 = marker (e.g. "- ", "* ", "1. ", "- [ ] ", "- [x] ")
    private static let listMarkerRegex = try! NSRegularExpression(
        pattern: #"^(\s*)([-*+]\s+(?:\[[ xX]\]\s+)?|\d+\.\s+)"#
    )

    /// If the cursor is on a list line, returns (leadingWhitespace, marker, hasContent).
    /// `marker` is the bullet/number portion (e.g. "- ", "1. ", "- [ ] ").
    private func parseListMarker(_ line: String) -> (indent: String, marker: String, hasContent: Bool)? {
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = Self.listMarkerRegex.firstMatch(in: line, range: range) else {
            return nil
        }
        let indent = ns.substring(with: match.range(at: 1))
        let marker = ns.substring(with: match.range(at: 2))
        let prefixLen = match.range.length
        let hasContent = prefixLen < ns.length
        return (indent, marker, hasContent)
    }

    /// Builds the next marker for list continuation.
    /// - Ordered lists: increments the number (e.g. "1. " → "2. ")
    /// - Checkbox items: resets to unchecked (e.g. "- [x] " → "- [ ] ")
    /// - Plain bullets: returns the same marker
    private func nextMarker(for marker: String) -> String {
        // Ordered: "1. " → "2. "
        if let dotRange = marker.range(of: #"^\d+\."#, options: .regularExpression) {
            let numStr = String(marker[dotRange].dropLast())  // drop the "."
            if let num = Int(numStr) {
                return "\(num + 1)." + String(marker[dotRange.upperBound...])
            }
        }
        // Checkbox: replace [x] with [ ]
        if let cbRange = marker.range(of: "[x]", options: .caseInsensitive) {
            var next = marker
            next.replaceSubrange(cbRange, with: "[ ]")
            return next
        }
        return marker
    }

    // MARK: - Override

    public override func insertNewline(_ sender: Any?) {
        let sel = selectedRange()
        guard sel.length == 0,
              let blockIdx = blockIndexForRawOffset(sel.location),
              blockIdx < blocks.count else {
            super.insertNewline(sender)
            return
        }

        let block = blocks[blockIdx]
        guard let (indent, marker, hasContent) = parseListMarker(block.content) else {
            super.insertNewline(sender)
            return
        }

        if hasContent {
            // Content present → insert newline + next marker.
            // If splitting mid-line and the next char is a space, consume it
            // so we don't get a double space after the marker.
            let next = indent + nextMarker(for: marker)
            var replaceRange = sel
            let nsRaw = rawSource as NSString
            if sel.location < nsRaw.length && nsRaw.character(at: sel.location) == 0x20 {
                replaceRange.length += 1
            }
            insertText("\n" + next, replacementRange: replaceRange)
        } else if !indent.isEmpty {
            // Indented empty list line → un-indent one level
            let maxRemove = (Self.indentUnit as NSString).length
            let leading = indent.prefix(while: { $0 == " " }).count
            let remove = indent.hasPrefix("\t") ? 1 : min(leading, maxRemove)
            let dedented = String(block.content.dropFirst(remove))
            insertText(dedented, replacementRange: block.range)
        } else {
            // Root-level empty list line → remove the marker entirely
            insertText("", replacementRange: block.range)
        }
    }
}
