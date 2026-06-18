import AppKit

// MARK: - Block-quote / Callout Continuation on Enter
//
// Pressing Return inside a block quote (including a callout) repeats the quote
// prefix on the next line — `> ` — so the quote/callout keeps going, the same
// way list items auto-continue. Pressing Return on an *empty* quote line removes
// the prefix and breaks out of the quote.

extension EditorTextView {

    /// Leading indent + one or more `>` levels (each with an optional single
    /// space), at the start of a line. Captures the *full* nesting depth so a
    /// nested callout/quote line `> > …` continues as `> > `, not `> `.
    private static let blockquotePrefixRegex = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:>[ \t]?)+"#
    )

    /// Continues a block quote / callout on Return. Returns true if it handled
    /// the newline.
    func handleBlockquoteNewline(at location: Int) -> Bool {
        let ns = rawSource as NSString
        guard location <= ns.length else { return false }

        // The line containing the cursor (without its trailing newline).
        let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
        var lineEnd = lineRange.upperBound
        if lineEnd > lineRange.location, ns.character(at: lineEnd - 1) == 0x0A { lineEnd -= 1 }
        let lineStart = lineRange.location
        let line = ns.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
        let lineNS = line as NSString

        guard let m = Self.blockquotePrefixRegex.firstMatch(
            in: line, range: NSRange(location: 0, length: lineNS.length)) else { return false }

        let prefix = lineNS.substring(with: m.range)
        let hasContent = m.range.length < lineNS.length

        if hasContent {
            // Continue the quote/callout at the same depth: newline + same prefix.
            insertText("\n" + prefix, replacementRange: NSRange(location: location, length: 0))
        } else {
            // Empty quote line → step out one nesting level (drop the last `>`).
            // At the top level this empties the line, breaking out of the quote.
            insertText(Self.reduceQuotePrefix(prefix),
                       replacementRange: NSRange(location: lineStart, length: lineEnd - lineStart))
        }
        return true
    }

    /// Drops the deepest `>` level from a quote prefix: `> > ` → `> `,
    /// `  > ` → `  ` (indent kept), `> ` → `` (broken out).
    static func reduceQuotePrefix(_ prefix: String) -> String {
        let ns = prefix as NSString
        let lastGT = ns.range(of: ">", options: .backwards)
        guard lastGT.location != NSNotFound else { return "" }
        return ns.substring(to: lastGT.location)
    }
}
