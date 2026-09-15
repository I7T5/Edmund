import Testing
import AppKit
@testable import EdmundCore

// Hard wrap / unwrap (Settings ▸ Edit ▸ Document ▸ "Detect hard wrap pattern
// for lines on document opening").
// Pure String → String, so no editor or window is involved.

@Suite("HardWrap")
struct HardWrapTests {

    /// Five words of ten characters each — 10, 21, 32 … so the break points are
    /// easy to reason about against the 80-column limit.
    private func words(_ n: Int) -> String {
        (1...n).map { String(repeating: "w", count: 9) + String($0 % 10) }
            .joined(separator: " ")
    }

    // MARK: - Wrap

    @Test("Wraps at the last space before column 80")
    func breaksAtColumn() {
        // 8 words × 10 chars + 7 spaces = 87 > 80; 7 words = 76 fits.
        let lines = HardWrap.wrap(words(8)).components(separatedBy: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].count == 76)
        #expect(lines.allSatisfy { !$0.hasSuffix(" ") })
    }

    @Test("A short paragraph is left alone")
    func shortParagraphUnchanged() {
        #expect(HardWrap.wrap("one two three") == "one two three")
    }

    @Test("A word longer than the column stays intact on its own line")
    func neverBreaksMidWord() {
        let giant = String(repeating: "x", count: 100)
        let wrapped = HardWrap.wrap("short \(giant) tail")
        #expect(wrapped.contains(giant))
        #expect(wrapped.components(separatedBy: "\n").contains(giant))
    }

    @Test("A break never puts a list marker at the start of a line")
    func neverCreatesListSyntax() {
        // "1." would land at column 0 on a naive greedy fill.
        let text = words(7) + " 1. 50 per unit"
        for line in HardWrap.wrap(text).components(separatedBy: "\n") {
            #expect(!line.hasPrefix("1."))
        }
    }

    @Test("A break never puts a heading, quote, dash or fence at line start")
    func neverCreatesOtherSyntax() {
        for token in ["#", "##", ">", "-", "*", "---", "===", "|", "```", "~~~"] {
            let wrapped = HardWrap.wrap(words(7) + " \(token) tail text here")
            for line in wrapped.components(separatedBy: "\n") {
                #expect(!line.hasPrefix(token), "\(token) reached line start")
            }
        }
    }

    @Test("A dash inside a word is not mistaken for a list marker")
    func hyphenatedWordStillBreaks() {
        let wrapped = HardWrap.wrap(words(7) + " -dash tail")
        // "-dash" is not a marker, so the fill is free to break in front of it.
        #expect(wrapped.contains("\n-dash"))
    }

    @Test("Paragraph indent is preserved on continuation lines")
    func preservesIndent() {
        let lines = HardWrap.wrap("  " + words(8)).components(separatedBy: "\n")
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.hasPrefix("  ") })
    }

    // MARK: - Unwrap

    @Test("A wrapped paragraph becomes one line")
    func joinsParagraph() {
        #expect(HardWrap.unwrap("one two\nthree four") == "one two three four")
    }

    @Test("Blank lines still separate paragraphs")
    func keepsParagraphBreaks() {
        #expect(HardWrap.unwrap("one\ntwo\n\nthree\nfour") == "one two\n\nthree four")
    }

    @Test("A two-space hard break survives the join")
    func keepsTwoSpaceHardBreak() {
        #expect(HardWrap.unwrap("one  \ntwo three") == "one  \ntwo three")
    }

    @Test("A trailing-backslash hard break survives the join")
    func keepsBackslashHardBreak() {
        #expect(HardWrap.unwrap("one\\\ntwo") == "one\\\ntwo")
    }

    @Test("An escaped backslash is not a hard break")
    func escapedBackslashJoins() {
        #expect(HardWrap.unwrap("one\\\\\ntwo") == "one\\\\ two")
    }

    @Test("A single trailing space does not double up in the join")
    func trimsInsignificantTrailingSpace() {
        #expect(HardWrap.unwrap("one \ntwo") == "one two")
    }

    @Test("Continuation-line indent is dropped when joining")
    func dropsContinuationIndent() {
        #expect(HardWrap.unwrap("  one\n  two") == "  one two")
    }

    @Test("A hard break survives a wrap too")
    func wrapKeepsHardBreak() {
        let wrapped = HardWrap.wrap("one  \ntwo")
        #expect(wrapped == "one  \ntwo")
    }

    // MARK: - Blocks that must never be touched

    /// Every kind the transform is supposed to copy through verbatim, each with
    /// a line long enough that a careless wrap would show up immediately.
    private var immuneDocument: String {
        let long = words(12)
        return """
        ---
        title: \(long)
        ---

        # \(long)

        ```swift
        let x = "\(long)"
        ```

            indented code \(long)

        | a | b |
        | --- | --- |
        | \(long) | y |

        > quoted \(long)

        - list item \(long)

        $$
        \(long)
        $$

        <div>\(long)</div>

        ***
        """
    }

    @Test("Fences, tables, headings, front matter, lists and quotes are copied through")
    func blocksAreImmune() {
        #expect(HardWrap.wrap(immuneDocument) == immuneDocument)
        #expect(HardWrap.unwrap(immuneDocument) == immuneDocument)
    }

    // MARK: - Round trips

    @Test("Wrapping an already-wrapped document changes nothing")
    func wrapIsIdempotent() {
        let once = HardWrap.wrap(words(30))
        #expect(HardWrap.wrap(once) == once)
    }

    @Test("Unwrapping an already-joined document changes nothing")
    func unwrapIsIdempotent() {
        let once = HardWrap.unwrap(words(30))
        #expect(HardWrap.unwrap(once) == once)
    }

    @Test("A document wrapped at 80 round-trips through unwrap and back")
    func roundTrip() {
        let wrapped = HardWrap.wrap("\(words(30))\n\n# Heading\n\n\(words(17))")
        #expect(HardWrap.wrap(HardWrap.unwrap(wrapped)) == wrapped)
    }

    @Test("Empty input is handled")
    func empty() {
        #expect(HardWrap.wrap("") == "")
        #expect(HardWrap.unwrap("") == "")
    }

    // MARK: - Detecting the column a file already uses

    /// The property that actually matters: whatever column is detected has to
    /// reproduce the file's own breaks exactly, so opening and saving is a
    /// no-op. Asserting a specific number would over-fit — a range of columns
    /// is genuinely indistinguishable from the breaks alone.
    private func detectRoundTrips(_ source: String, line: Int = #line) -> Bool {
        guard let column = HardWrap.detectColumn(source) else { return false }
        return HardWrap.wrap(HardWrap.unwrap(source), column: column) == source
    }

    @Test("A file wrapped at 72 round-trips at its own width")
    func detects72() {
        let source = HardWrap.wrap(words(40), column: 72)
        #expect(HardWrap.detectColumn(source) != nil)
        #expect(detectRoundTrips(source))
        // 80 is not consistent with breaks made at 72, so it must not be chosen.
        #expect(HardWrap.detectColumn(source) != 80)
    }

    @Test("A file wrapped at 80 is detected as 80")
    func detects80() {
        #expect(HardWrap.detectColumn(HardWrap.wrap(words(40))) == 80)
    }

    @Test("Every width from 40 to 120 round-trips")
    func detectsManyWidths() {
        for column in stride(from: 40, through: 120, by: 7) {
            let source = HardWrap.wrap(words(60), column: column)
            #expect(detectRoundTrips(source), "column \(column) did not round-trip")
        }
    }

    @Test("Detection survives real prose, not just uniform words")
    func detectsProse() {
        let prose = "The quick brown fox jumps over the lazy dog while a "
            + "surprisingly verbose narrator describes the entire affair in "
            + "detail that nobody asked for, at considerable length."
        for column in [60, 72, 80, 100] {
            let source = HardWrap.wrap(prose, column: column)
            #expect(detectRoundTrips(source), "column \(column) did not round-trip")
        }
    }

    @Test("An unwrapped file has no detectable column")
    func noColumnWhenUnwrapped() {
        #expect(HardWrap.detectColumn("one long single line paragraph") == nil)
        #expect(HardWrap.detectColumn("") == nil)
    }

    @Test("A hard break is not read as a wrap point")
    func hardBreakIsNotAColumnHint() {
        // Two short lines joined by a hard break say nothing about the column.
        #expect(HardWrap.detectColumn("one  \ntwo") == nil)
    }

    @Test("Inconsistently wrapped paragraphs report no column")
    func inconsistentReportsNil() {
        // A long line in one paragraph rules out the narrow break in the other.
        let source = HardWrap.wrap(words(20), column: 110) + "\n\n"
            + HardWrap.wrap(words(20), column: 40)
        #expect(HardWrap.detectColumn(source) == nil)
    }

    @Test("Repeated open/save cycles don't drift the column")
    func detectionIsStable() {
        // The failure this guards: taking the low end of the consistent range
        // writes slightly narrower each time, and the document creeps in.
        for start in [60, 72, 80, 100] {
            var source = HardWrap.wrap(words(60), column: start)
            let first = HardWrap.detectColumn(source)
            for _ in 0..<5 {
                let column = HardWrap.detectColumn(source) ?? HardWrap.column
                #expect(column == first, "column drifted from \(first ?? -1) to \(column)")
                source = HardWrap.wrap(HardWrap.unwrap(source), column: column)
            }
        }
    }

    @Test("A lone overlong word doesn't drag the detected column up")
    func loneWordDoesNotConstrain() {
        let giant = String(repeating: "x", count: 200)
        let source = HardWrap.wrap("\(words(20)) \(giant) \(words(20))", column: 72)
        #expect(detectRoundTrips(source))
    }
}

// The editor side: which documents count as hard-wrapped, and the Edit ▸ Hard
// Wrap Paragraphs command.

@Suite("HardWrap — editor")
struct HardWrapEditorTests {

    private func words(_ n: Int) -> String {
        (1...n).map { String(repeating: "w", count: 9) + String($0 % 10) }
            .joined(separator: " ")
    }

    @Test("Opening a wrapped file joins it and flags the document")
    @MainActor func loadUnwrapsAndFlags() {
        let editor = makeEditor()
        editor.loadContent("one two\nthree four", unwrapHardWrapping: true)
        #expect(editor.rawSource == "one two three four")
        #expect(editor.wasHardWrapped)
    }

    @Test("Opening a file that was never wrapped leaves it alone and unflagged")
    @MainActor func loadLeavesUnwrappedFileAlone() {
        let editor = makeEditor()
        editor.loadContent("one line\n\nanother line", unwrapHardWrapping: true)
        #expect(editor.rawSource == "one line\n\nanother line")
        #expect(!editor.wasHardWrapped)
    }

    @Test("Opening without the setting never joins or flags")
    @MainActor func loadWithoutSettingIsInert() {
        let editor = makeEditor()
        editor.loadContent("one two\nthree four")
        #expect(editor.rawSource == "one two\nthree four")
        #expect(!editor.wasHardWrapped)
    }

    @Test("CRLF is still detected when unwrapping on open")
    @MainActor func loadKeepsLineEndingDetection() {
        let editor = makeEditor()
        editor.loadContent("one two\r\nthree four", unwrapHardWrapping: true)
        #expect(editor.originalLineEnding == .crlf)
        #expect(editor.rawSource == "one two three four")
    }

    @Test("The command wraps the whole document and leaves storage == rawSource")
    @MainActor func commandWrapsDocument() {
        let editor = makeEditor()
        editor.loadContent(words(20))
        editor.hardWrapParagraphs(nil)
        #expect(editor.rawSource.contains("\n"))
        #expect(editor.textStorage?.string == editor.rawSource)
        for line in editor.rawSource.components(separatedBy: "\n") {
            #expect(line.count <= HardWrap.column)
        }
    }

    /// The flag describes the file on disk, so a command that only rewrites the
    /// buffer must not set it — otherwise undoing the wrap would leave the next
    /// save wrapping the text straight back.
    @Test("The command never marks the document hard-wrapped")
    @MainActor func commandDoesNotFlagDocument() {
        let editor = makeEditor()
        editor.loadContent(words(20))
        editor.hardWrapParagraphs(nil)
        #expect(!editor.wasHardWrapped)
        editor.undo(nil)
        #expect(!editor.wasHardWrapped)
    }

    @Test("The command undoes in a single step")
    @MainActor func commandIsOneUndoStep() {
        let editor = makeEditor()
        let original = words(20)
        editor.loadContent(original)
        editor.hardWrapParagraphs(nil)
        #expect(editor.rawSource != original)
        editor.undo(nil)
        #expect(editor.rawSource == original)
        #expect(editor.textStorage?.string == original)
    }

    @Test("Wrapping an already-wrapped document records no undo step")
    @MainActor func commandIsInertWhenWrapped() {
        let editor = makeEditor()
        editor.loadContent(HardWrap.wrap(words(20)))
        let before = editor.rawSource
        editor.hardWrapParagraphs(nil)
        #expect(editor.rawSource == before)
        editor.undo(nil)
        #expect(editor.rawSource == before)
    }

    @Test("A selection wraps only its own paragraph and doesn't flag the document")
    @MainActor func commandHonorsSelection() {
        let editor = makeEditor()
        let second = words(20)
        editor.loadContent("short first paragraph\n\n\(second)")
        let secondStart = ("short first paragraph\n\n" as NSString).length
        editor.setSelectedRange(NSRange(location: secondStart,
                                        length: (second as NSString).length))
        editor.hardWrapParagraphs(nil)
        #expect(editor.rawSource.hasPrefix("short first paragraph\n\n"))
        #expect(editor.rawSource.contains("\n"))
        #expect(editor.textStorage?.string == editor.rawSource)
    }

    @Test("A file wrapped at 72 opens, saves and stays at 72")
    @MainActor func detectedColumnSurvivesRoundTrip() {
        let editor = makeEditor()
        let source = HardWrap.wrap(words(40), column: 72)
        editor.loadContent(source, unwrapHardWrapping: true)
        #expect(editor.wasHardWrapped)
        #expect(editor.hardWrapColumn == 72)
        // What `Document.data(ofType:)` writes.
        #expect(HardWrap.wrap(editor.rawSource, column: editor.hardWrapColumn) == source)
    }

    @Test("A file with no detectable column falls back to 80")
    @MainActor func inconsistentFileFallsBackTo80() {
        let editor = makeEditor()
        // Two paragraphs wrapped at incompatible widths: no single column
        // explains both, so there is nothing to honour.
        let source = HardWrap.wrap(words(20), column: 110) + "\n\n"
            + HardWrap.wrap(words(20), column: 40)
        editor.loadContent(source, unwrapHardWrapping: true)
        #expect(editor.wasHardWrapped)
        #expect(editor.hardWrapColumn == HardWrap.column)
    }

    @Test("An unwrapped file keeps the default column")
    @MainActor func unwrappedFileKeepsDefaultColumn() {
        let editor = makeEditor()
        editor.loadContent("one long single line paragraph", unwrapHardWrapping: true)
        #expect(!editor.wasHardWrapped)
        #expect(editor.hardWrapColumn == HardWrap.column)
    }

    @Test("The menu command uses the document's detected column")
    @MainActor func commandUsesDetectedColumn() {
        let editor = makeEditor()
        editor.loadContent(HardWrap.wrap(words(40), column: 60), unwrapHardWrapping: true)
        #expect(editor.hardWrapColumn == 60)
        editor.hardWrapParagraphs(nil)
        for line in editor.rawSource.components(separatedBy: "\n") {
            #expect(line.count <= 60)
        }
    }

    @Test("The command leaves a fenced code block untouched")
    @MainActor func commandSkipsFences() {
        let editor = makeEditor()
        let source = "```\nlet x = \"\(words(20))\"\n```"
        editor.loadContent(source)
        editor.hardWrapParagraphs(nil)
        #expect(editor.rawSource == source)
    }
}
