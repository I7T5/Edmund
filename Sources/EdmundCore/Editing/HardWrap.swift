// Hard wrap: reflowing paragraphs to a fixed column, and joining them back.
//
// The two directions are inverses used at opposite ends of a document's life.
// Opening a file `unwrap`s it so each paragraph is one long logical line and
// editing never fights the wrap; saving `wrap`s it back so the file on disk
// keeps its shape and diffs stay line-sized. Both are pure String → String, so
// they are testable without an editor and safe to call off the load/save path.
//
// Only `.paragraph` blocks are touched. Everything else — fences, tables,
// headings, front matter — is copied through byte for byte.

import Foundation

public enum HardWrap {
    /// Where `wrap` breaks. A word that doesn't fit on its own overflows past
    /// this rather than being split.
    public static let column = 80

    /// Reflows every paragraph to `column`. Other block kinds are untouched.
    public static func wrap(_ source: String, features: MarkdownFeatures = .all,
                            column: Int = HardWrap.column) -> String {
        transformParagraphs(BlockParser.parse(source, features: features)) {
            fillParagraph($0, column: column)
        }
    }

    /// The column this document was already wrapped at, or nil when its
    /// paragraphs aren't consistently wrapped (or aren't wrapped at all).
    ///
    /// Guessing from the longest line would be off by however much the next
    /// word overhung, and re-wrapping at a guess moves text that was fine.
    /// Instead the existing line breaks are read as *constraints* on the column
    /// a greedy fill must have used: every line that isn't one long word had to
    /// fit, so `column >= len(line)`; and every break had to be forced, so
    /// `column < len(line) + 1 + len(next word)`. That leaves a range of columns
    /// which all reproduce the file's breaks exactly — so any of them
    /// round-trips losslessly, and the choice only affects text typed later.
    ///
    /// Which one to take is therefore a question about *future* text, and the
    /// endpoints are both wrong for it. The low end is the longest line the file
    /// happens to contain, which is a little under the real column, so writing
    /// at it would shave a few characters off the width on every save and creep
    /// the document narrower. So a conventional width is preferred when one
    /// qualifies, and the widest consistent column is the fallback — erring wide
    /// can't compound the way erring narrow does.
    public static func detectColumn(_ source: String,
                                    features: MarkdownFeatures = .all) -> Int? {
        detectColumn(BlockParser.parse(source, features: features))
    }

    /// Preference order when several columns fit the file's breaks equally well.
    private static let conventionalColumns = [80, 100, 120, 72, 60]

    static func detectColumn(_ blocks: [Block]) -> Int? {
        var lowest = 0            // the longest line that had to fit
        var highest = Int.max     // the tightest "this break was forced" bound
        var sawBreak = false
        // The previous paragraph line, or nil at a paragraph boundary — plain
        // text parses one `.paragraph` block per line, so consecutive paragraph
        // blocks are exactly the pairs a wrap could have broken between.
        var previous: String?

        for block in blocks {
            guard block.kind == .paragraph else { previous = nil; continue }
            let line = block.content
            // A line holding one overlong word was emitted whatever the column
            // was, so it constrains nothing.
            if line.trimmingCharacters(in: .whitespaces).contains(" ") {
                lowest = max(lowest, line.count)
            }
            // A hard break ended that line for its own reasons, not the column's.
            if let previous, !endsWithHardBreak(previous),
               let next = line.split(separator: " ").first {
                sawBreak = true
                highest = min(highest, previous.count + next.count)
            }
            previous = line
        }

        guard sawBreak, lowest <= highest else { return nil }
        let consistent = lowest...highest
        return conventionalColumns.first(where: consistent.contains) ?? highest
    }

    /// Joins each paragraph's soft-broken lines into one line. Other block kinds
    /// are untouched.
    public static func unwrap(_ source: String, features: MarkdownFeatures = .all) -> String {
        transformParagraphs(BlockParser.parse(source, features: features), unwrapParagraph)
    }

    /// `unwrap` and `detectColumn` over a single parse — the pair every document
    /// open needs. Worth its own entry point because parsing *is* the cost here:
    /// the two transforms together are a few ms, while each parse of a 60 KB
    /// document is ~60 ms, so doing it once rather than twice is the whole
    /// optimization. `column` is nil when the file isn't consistently wrapped.
    public static func unwrapDetectingColumn(
        _ source: String, features: MarkdownFeatures = .all
    ) -> (text: String, column: Int?) {
        let blocks = BlockParser.parse(source, features: features)
        return (transformParagraphs(blocks, unwrapParagraph), detectColumn(blocks))
    }

    /// Block boundaries come from the real parser, so "is this line inside a
    /// fence" needs no separate scanner. Blocks tile the document and rejoin
    /// with `\n` (the invariant `verifyEditorInvariants` already checks), so
    /// rebuilding this way is lossless for every block we don't rewrite.
    ///
    /// `body` is handed a whole *run* of consecutive paragraph blocks, not one
    /// block: plain text parses one `.paragraph` per source line, so a wrapped
    /// paragraph arrives as several blocks and joining it back up is the entire
    /// job. A run's members rejoin with `\n` like the blocks themselves do, so
    /// an identity `body` reproduces the input exactly.
    ///
    /// ponytail: `.listItem` and `.quoteRun` are deliberately left alone — a
    /// list needs a hanging continuation indent and a quote needs its `> `
    /// re-emitted per line, and neither is as obviously lossless as a bare
    /// paragraph. Add when asked.
    private static func transformParagraphs(_ blocks: [Block],
                                            _ body: (String) -> String) -> String {
        var out: [String] = []
        var run: [String] = []

        func flushRun() {
            guard !run.isEmpty else { return }
            out.append(body(run.joined(separator: "\n")))
            run.removeAll()
        }

        for block in blocks {
            if block.kind == .paragraph {
                run.append(block.content)
            } else {
                flushRun()
                out.append(block.content)
            }
        }
        flushRun()
        return out.joined(separator: "\n")
    }

    // MARK: - Unwrap

    /// Joins the paragraph's lines with a single space, except across a GFM
    /// hard break — two trailing spaces or a trailing backslash are content,
    /// not formatting, and joining there would delete a visible line break.
    private static func unwrapParagraph(_ content: String) -> String {
        let lines = content.components(separatedBy: "\n")
        var out: [String] = []
        var run: [String] = []

        for (i, line) in lines.enumerated() {
            // The first line keeps the paragraph's own indent; continuation
            // lines lose theirs, since it was only there to line the wrap up.
            let stripped = i == 0 ? line : trimmingLeadingSpaces(line)
            if endsWithHardBreak(line) {
                // The break-marking line closes the run last, so its trailing
                // marker survives the join and lands at end of line.
                run.append(stripped)
                out.append(run.joined(separator: " "))
                run.removeAll()
            } else {
                run.append(trimmingTrailingSpaces(stripped))
            }
        }
        if !run.isEmpty { out.append(run.joined(separator: " ")) }
        return out.joined(separator: "\n")
    }

    // MARK: - Wrap

    /// Unwrapping first means each line handed to `fill` is exactly one
    /// hard-break-delimited segment, so the fill never has to reason about
    /// where the previous wrap happened to land.
    private static func fillParagraph(_ content: String, column: Int) -> String {
        unwrapParagraph(content)
            .components(separatedBy: "\n")
            .map { fill($0, column: column) }
            .joined(separator: "\n")
    }

    private static func fill(_ line: String, column: Int) -> String {
        // A trailing two-space hard break would be eaten by the word split, so
        // set it aside and put it back on the last line. A trailing backslash
        // needs no such care — it travels glued to its word.
        let body = line.hasSuffix("  ") ? trimmingTrailingSpaces(line) : line
        let hardBreak = String(line.dropFirst(body.count))

        let indent = String(body.prefix { $0 == " " || $0 == "\t" })
        let words = body.dropFirst(indent.count).split(separator: " ").map(String.init)
        guard let first = words.first else { return line }

        var lines: [String] = []
        var current = indent + first
        for word in words.dropFirst() {
            let candidate = current + " " + word
            // ponytail: `count` is grapheme clusters, so a CJK character counts
            // as one column even though it draws double-width. Swap in a width
            // table if wrapping CJK prose ever matters.
            if candidate.count <= column || opensBlock(word) {
                current = candidate
            } else {
                lines.append(current)
                current = indent + word
            }
        }
        lines.append(current + hardBreak)
        return lines.joined(separator: "\n")
    }

    /// Whether starting a line with this word would create block syntax that
    /// wasn't there before. Breaking in front of the `1.` in "…costs 1. 50 per
    /// unit…" turns the rest of the paragraph into an ordered list on the next
    /// parse, so such a break is refused and the line overflows instead.
    ///
    /// Checking the word alone is exact: the fill splits on spaces, so a word
    /// at line start is always followed by a space or end of line — precisely
    /// the context these markers need.
    private static func opensBlock(_ word: String) -> Bool {
        guard let firstChar = word.first else { return false }

        switch firstChar {
        case "-", "+", "*", "_", "=":
            // A bare marker (`-`), or a run of them (`---`, `===`, `***`) that
            // is a thematic break or a setext underline. `-foo` is neither.
            return word.allSatisfy { $0 == firstChar }
        case ">", "|":
            // Both allow the space after them to be omitted.
            return true
        case "#":
            let hashes = word.prefix { $0 == "#" }
            return hashes.count == word.count && hashes.count <= 6
        case "`", "~":
            return word.hasPrefix("```") || word.hasPrefix("~~~")
        default:
            // An ordered-list marker: digits, then exactly one `.` or `)`.
            let digits = word.prefix(while: \.isNumber)
            guard !digits.isEmpty, digits.count <= 9, word.count == digits.count + 1
            else { return false }
            return word.hasSuffix(".") || word.hasSuffix(")")
        }
    }

    // MARK: - Line helpers

    /// A GFM hard break: two or more trailing spaces, or an unescaped trailing
    /// backslash (an even run of backslashes is an escaped literal, not a break).
    private static func endsWithHardBreak(_ line: String) -> Bool {
        if line.hasSuffix("  ") { return true }
        guard line.hasSuffix("\\") else { return false }
        return line.reversed().prefix { $0 == "\\" }.count % 2 == 1
    }

    private static func trimmingTrailingSpaces(_ line: String) -> String {
        var result = line
        while result.hasSuffix(" ") || result.hasSuffix("\t") { result.removeLast() }
        return result
    }

    private static func trimmingLeadingSpaces(_ line: String) -> String {
        String(line.drop { $0 == " " || $0 == "\t" })
    }
}
