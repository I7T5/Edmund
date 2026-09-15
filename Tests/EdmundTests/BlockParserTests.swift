import Testing
import Foundation
@testable import EdmundCore

@Suite("BlockParser")
struct BlockParserTests {

    // MARK: - Basic Splitting

    @Test("Empty string produces one empty block")
    func emptyString() {
        let blocks = BlockParser.parse("")
        #expect(blocks.count == 1)
        #expect(blocks[0].content == "")
        #expect(blocks[0].range == NSRange(location: 0, length: 0))
    }

    @Test("A callout merges its block-quote lines into one block")
    func calloutMerges() {
        let blocks = BlockParser.parse("> [!note]\n> line one\n> line two\n\nafter")
        // The three `>` lines form one callout block; blank + "after" follow.
        #expect(blocks.count == 3)
        #expect(blocks[0].content == "> [!note]\n> line one\n> line two")
        #expect(blocks[2].content == "after")
    }

    @Test("Consecutive block-quote lines merge into one block")
    func blockquoteLinesMerge() {
        // One NSTextBlock per quote (vs one per line) avoids the NSTextView
        // table-cell deletion restriction at per-line boundaries.
        let blocks = BlockParser.parse("> a\n> b\n\nafter")
        #expect(blocks.count == 3)
        #expect(blocks[0].content == "> a\n> b")
        #expect(blocks[2].content == "after")
    }

    @Test("An unknown [!type] still merges as a plain block quote")
    func unknownCalloutMergesAsQuote() {
        let blocks = BlockParser.parse("> [!bogus]\n> b")
        #expect(blocks.count == 1)
    }

    @Test("Single line produces one block")
    func singleLine() {
        let blocks = BlockParser.parse("hello")
        #expect(blocks.count == 1)
        #expect(blocks[0].content == "hello")
        #expect(blocks[0].range == NSRange(location: 0, length: 5))
    }

    @Test("Two lines produce two blocks")
    func twoLines() {
        let blocks = BlockParser.parse("hello\nworld")
        #expect(blocks.count == 2)
        #expect(blocks[0].content == "hello")
        #expect(blocks[0].range == NSRange(location: 0, length: 5))
        #expect(blocks[1].content == "world")
        #expect(blocks[1].range == NSRange(location: 6, length: 5))
    }

    @Test("Three lines produce three blocks")
    func threeLines() {
        let blocks = BlockParser.parse("a\nb\nc")
        #expect(blocks.count == 3)
        #expect(blocks[0].content == "a")
        #expect(blocks[1].content == "b")
        #expect(blocks[2].content == "c")
        #expect(blocks[0].range == NSRange(location: 0, length: 1))
        #expect(blocks[1].range == NSRange(location: 2, length: 1))
        #expect(blocks[2].range == NSRange(location: 4, length: 1))
    }

    @Test("Trailing newline creates empty block (Enter at end)")
    func trailingNewline() {
        let blocks = BlockParser.parse("hello\n")
        #expect(blocks.count == 2)
        #expect(blocks[0].content == "hello")
        #expect(blocks[1].content == "")
        #expect(blocks[1].range == NSRange(location: 6, length: 0))
    }

    @Test("Multiple trailing newlines create multiple empty blocks")
    func multipleTrailingNewlines() {
        let blocks = BlockParser.parse("hello\n\n")
        #expect(blocks.count == 3)
        #expect(blocks[0].content == "hello")
        #expect(blocks[1].content == "")
        #expect(blocks[2].content == "")
    }

    @Test("Only newlines produce empty blocks")
    func onlyNewlines() {
        let blocks = BlockParser.parse("\n\n")
        #expect(blocks.count == 3)
        for block in blocks {
            #expect(block.content == "")
        }
    }

    // MARK: - Ranges Are Contiguous

    @Test("Block ranges cover the full string with separators between them")
    func rangesContiguous() {
        let text = "alpha\nbeta\ngamma"
        let blocks = BlockParser.parse(text)
        let nsText = text as NSString

        // First block starts at 0
        #expect(blocks[0].range.location == 0)

        // Each block's end + 1 (separator) == next block's start
        for i in 0..<(blocks.count - 1) {
            #expect(blocks[i].range.upperBound + 1 == blocks[i + 1].range.location)
        }

        // Last block ends at or before string length
        #expect(blocks.last!.range.upperBound <= nsText.length)
    }

    // MARK: - ID Preservation

    @Test("Re-parsing unchanged text preserves block IDs")
    func idPreservation() {
        let blocks1 = BlockParser.parse("hello\nworld")
        let blocks2 = BlockParser.parse("hello\nworld", previous: blocks1)

        #expect(blocks1[0].id == blocks2[0].id)
        #expect(blocks1[1].id == blocks2[1].id)
    }

    @Test("Changed block gets a new ID")
    func idChangedBlock() {
        let blocks1 = BlockParser.parse("hello\nworld")
        let blocks2 = BlockParser.parse("hello\nearth", previous: blocks1)

        #expect(blocks1[0].id == blocks2[0].id)   // "hello" unchanged
        #expect(blocks1[1].id != blocks2[1].id)   // "world" → "earth"
    }

    @Test("Added block gets a new ID, existing blocks keep theirs")
    func idAddedBlock() {
        let blocks1 = BlockParser.parse("hello\nworld")
        let blocks2 = BlockParser.parse("hello\nworld\nnew", previous: blocks1)

        #expect(blocks2.count == 3)
        #expect(blocks1[0].id == blocks2[0].id)
        #expect(blocks1[1].id == blocks2[1].id)
        // blocks2[2] is new — just verify it exists with the right content
        #expect(blocks2[2].content == "new")
    }

    @Test("Removed block: remaining blocks keep their IDs")
    func idRemovedBlock() {
        let blocks1 = BlockParser.parse("hello\nworld\nfoo")
        let blocks2 = BlockParser.parse("hello\nfoo", previous: blocks1)

        #expect(blocks2.count == 2)
        #expect(blocks1[0].id == blocks2[0].id)   // "hello"
        #expect(blocks1[2].id == blocks2[1].id)   // "foo"
    }

    @Test("Each previous block ID is used at most once")
    func idUniqueness() {
        let blocks1 = BlockParser.parse("a\na\na")  // three identical blocks
        let blocks2 = BlockParser.parse("a\na\na", previous: blocks1)

        // Each reused at most once: all three IDs should still be unique
        let ids = blocks2.map(\.id)
        #expect(Set(ids).count == 3)
    }

    // MARK: - Markdown Content (parser doesn't interpret, just preserves)

    @Test("Markdown syntax is preserved as-is in block content")
    func markdownPreserved() {
        let text = "**bold**\n*italic*\n`code`"
        let blocks = BlockParser.parse(text)
        #expect(blocks[0].content == "**bold**")
        #expect(blocks[1].content == "*italic*")
        #expect(blocks[2].content == "`code`")
    }

    // MARK: - Edge Cases

    @Test("Single character")
    func singleChar() {
        let blocks = BlockParser.parse("x")
        #expect(blocks.count == 1)
        #expect(blocks[0].content == "x")
        #expect(blocks[0].range == NSRange(location: 0, length: 1))
    }

    @Test("Single newline produces two empty blocks")
    func singleNewline() {
        let blocks = BlockParser.parse("\n")
        #expect(blocks.count == 2)
        #expect(blocks[0].content == "")
        #expect(blocks[1].content == "")
    }

    @Test("Ranges are correct for multi-byte characters")
    func multiByte() {
        // NSRange uses UTF-16 offsets. "café" is 4 UTF-16 code units,
        // "é" is 1 code unit (U+00E9).
        let text = "café\nnext"
        let blocks = BlockParser.parse(text)
        #expect(blocks[0].content == "café")
        #expect(blocks[0].range == NSRange(location: 0, length: 4))
        #expect(blocks[1].content == "next")
        #expect(blocks[1].range == NSRange(location: 5, length: 4))
    }

    @Test("Emoji ranges use UTF-16 length")
    func emoji() {
        // "👋" is 2 UTF-16 code units (surrogate pair)
        let text = "👋\nhi"
        let blocks = BlockParser.parse(text)
        #expect(blocks[0].content == "👋")
        #expect(blocks[0].range.length == ("👋" as NSString).length)
        #expect(blocks[1].content == "hi")
    }

    // MARK: - Table Merging

    @Test("Table with header and separator merges into single block")
    func tableMerge() {
        let text = "| A | B |\n| --- | --- |\n| 1 | 2 |"
        let blocks = BlockParser.parse(text)
        #expect(blocks.count == 1)
        #expect(blocks[0].content == text)
    }

    @Test("Table between paragraphs")
    func tableBetweenParagraphs() {
        let text = "above\n| A | B |\n| --- | --- |\n| 1 | 2 |\nbelow"
        let blocks = BlockParser.parse(text)
        #expect(blocks.count == 3)
        #expect(blocks[0].content == "above")
        #expect(blocks[1].content == "| A | B |\n| --- | --- |\n| 1 | 2 |")
        #expect(blocks[2].content == "below")
    }

    @Test("Table with multiple data rows")
    func tableMultipleRows() {
        let text = "| H1 | H2 |\n| --- | --- |\n| a | b |\n| c | d |"
        let blocks = BlockParser.parse(text)
        #expect(blocks.count == 1)
        #expect(blocks[0].content == text)
    }

    @Test("Single pipe line without separator is not a table")
    func singlePipeNotTable() {
        let text = "| not a table |"
        let blocks = BlockParser.parse(text)
        #expect(blocks.count == 1)
        #expect(blocks[0].content == "| not a table |")
    }

    @Test("Table range covers full text")
    func tableRange() {
        let text = "| A |\n| --- |\n| 1 |"
        let blocks = BlockParser.parse(text)
        #expect(blocks[0].range == NSRange(location: 0, length: (text as NSString).length))
    }

    @Test("Delimiter row with fewer cells than the header is not a table")
    func tableRejectsMismatchedDelimiterCount() {
        let blocks = BlockParser.parse("| a | b |\n|---|")
        #expect(blocks.map(\.kind) != [.table])
    }

    @Test("Delimiter row with matching cell count is still a table")
    func tableAcceptsMatchingDelimiterCount() {
        let blocks = BlockParser.parse("| a | b |\n|---|---|")
        #expect(blocks.map(\.kind) == [.table])
    }

    /// A separator may use a single dash per column, not only three. Requiring
    /// `---` misread `- | -` as a bullet list (its leading `- ` looked like a
    /// marker) instead of a table separator.
    @Test("A single-dash delimiter row makes a table")
    func tableAcceptsSingleDashDelimiter() {
        #expect(BlockParser.parse("a | b\n- | -").map(\.kind) == [.table])
        #expect(BlockParser.parse("| a | b |\n| :- | -: |").map(\.kind) == [.table])
        #expect(BlockParser.parse("a | b\n- | -\nc | d").map(\.kind) == [.table])
    }

    /// A bullet list is still a bullet list — a `- ` line with no pipe, or with
    /// non-delimiter content, is not a separator.
    @Test("A real bullet list is not mistaken for a separator")
    func bulletListIsNotASeparator() {
        #expect(BlockParser.parse("- one\n- two").map(\.kind) == [.listItem, .listItem])
        // A pipe in list content does not make the line a delimiter row.
        #expect(BlockParser.parse("intro\n- a | b").map(\.kind) == [.paragraph, .listItem])
    }

    /// A setext underline needs a run of three now, not one: a lone dash or two
    /// under a line turned it into a heading by accident. Three matches the
    /// `---`/`===` the eye already reads as a rule.
    @Test("Setext underline needs three or more")
    func setextNeedsThree() {
        #expect(BlockParser.parse("Title\n===").map(\.kind) == [.heading(level: 1)])
        #expect(BlockParser.parse("Title\n---").map(\.kind) == [.heading(level: 2)])
        // One or two: not a heading — the line above stays a paragraph.
        #expect(BlockParser.parse("Title\n=").map(\.kind) == [.paragraph, .paragraph])
        #expect(BlockParser.parse("Title\n--").map(\.kind) == [.paragraph, .paragraph])
    }

    /// A thematic break still needs three, unchanged.
    @Test("Thematic break needs three")
    func thematicBreakNeedsThree() {
        #expect(BlockParser.parse("---").map(\.kind) == [.thematicBreak])
        #expect(BlockParser.parse("***").map(\.kind) == [.thematicBreak])
        #expect(BlockParser.parse("--").map(\.kind) == [.paragraph])
    }

    // MARK: - Code Fence Merging

    @Test("Fenced code block merges into single block")
    func codeFenceMerge() {
        let text = "```\nhello\n```"
        let blocks = BlockParser.parse(text)
        #expect(blocks.count == 1)
        #expect(blocks[0].content == "```\nhello\n```")
    }

    @Test("Code fence with language merges into single block")
    func codeFenceWithLanguage() {
        let text = "```swift\nlet x = 1\n```"
        let blocks = BlockParser.parse(text)
        #expect(blocks.count == 1)
        #expect(blocks[0].content == "```swift\nlet x = 1\n```")
    }

    @Test("Tilde code fence merges into single block")
    func tildeFenceMerge() {
        let text = "~~~\ncode\n~~~"
        let blocks = BlockParser.parse(text)
        #expect(blocks.count == 1)
        #expect(blocks[0].content == "~~~\ncode\n~~~")
    }

    @Test("Code fence between paragraphs")
    func codeFenceBetweenParagraphs() {
        let text = "above\n```\ncode\n```\nbelow"
        let blocks = BlockParser.parse(text)
        #expect(blocks.count == 3)
        #expect(blocks[0].content == "above")
        #expect(blocks[1].content == "```\ncode\n```")
        #expect(blocks[2].content == "below")
    }

    @Test("Unclosed code fence merges to end of document")
    func unclosedFence() {
        let text = "```\nline1\nline2"
        let blocks = BlockParser.parse(text)
        #expect(blocks.count == 1)
        #expect(blocks[0].content == "```\nline1\nline2")
    }

    @Test("Code fence with multiple content lines")
    func multiLineFence() {
        let text = "```\na\nb\nc\n```"
        let blocks = BlockParser.parse(text)
        #expect(blocks.count == 1)
        #expect(blocks[0].content.contains("a\nb\nc"))
    }

    @Test("Multi-line $$ display math merges into a single block")
    func displayMathMerge() {
        let text = "$$\nx = y\n$$"
        let blocks = BlockParser.parse(text)
        #expect(blocks.count == 1)
        #expect(blocks[0].content == "$$\nx = y\n$$")
    }

    @Test("One-line $$…$$ stays a single block")
    func displayMathOneLine() {
        let blocks = BlockParser.parse("$$ x = y $$")
        #expect(blocks.count == 1)
        #expect(blocks[0].content == "$$ x = y $$")
    }

    @Test("Display math between paragraphs splits correctly")
    func displayMathBetweenParagraphs() {
        let text = "above\n$$\nx\n$$\nbelow"
        let blocks = BlockParser.parse(text)
        #expect(blocks.count == 3)
        #expect(blocks[0].content == "above")
        #expect(blocks[1].content == "$$\nx\n$$")
        #expect(blocks[2].content == "below")
    }

    @Test("Display math opener with content on the same line")
    func displayMathOpenerWithContent() {
        let text = "$$ x +\ny $$"
        let blocks = BlockParser.parse(text)
        #expect(blocks.count == 1)
        #expect(blocks[0].content == "$$ x +\ny $$")
    }

    // A `$$…$$` display block whose opener sits after a list marker spans
    // several source lines; without merging, the opener and closer land in
    // different blocks and the display-math span can't form.
    @Test("A list item's multi-line $$ display block merges into one block")
    func listDisplayMathMerges() {
        let text = "1. $$\\begin{aligned}\nu&=1 \\\\ v&=2\n\\end{aligned}$$\n2. next"
        let blocks = BlockParser.parse(text)
        #expect(blocks.count == 2)
        #expect(blocks[0].content == "1. $$\\begin{aligned}\nu&=1 \\\\ v&=2\n\\end{aligned}$$")
        #expect(blocks[1].content == "2. next")
    }

    @Test("A bullet item's multi-line $$ display block merges into one block")
    func bulletDisplayMathMerges() {
        let text = "- $$\na=b\n$$\n- next"
        let blocks = BlockParser.parse(text)
        #expect(blocks.count == 2)
        #expect(blocks[0].content == "- $$\na=b\n$$")
        #expect(blocks[1].content == "- next")
    }

    @Test("A single-line list item with $$…$$ stays one block (no merge needed)")
    func listDisplayMathSingleLine() {
        let blocks = BlockParser.parse("1. $$x=y$$\n2. next")
        #expect(blocks.count == 2)
        #expect(blocks[0].content == "1. $$x=y$$")
        #expect(blocks[1].content == "2. next")
    }

    @Test("A plain list item is unaffected by the display-math merge rule")
    func plainListItemUnaffectedByMathMerge() {
        let blocks = BlockParser.parse("1. hello\n2. world")
        #expect(blocks.count == 2)
        #expect(blocks[0].content == "1. hello")
        #expect(blocks[1].content == "2. world")
    }

    @Test("Code fence range covers full text")
    func codeFenceRange() {
        let text = "```\nhello\n```"
        let blocks = BlockParser.parse(text)
        #expect(blocks[0].range == NSRange(location: 0, length: (text as NSString).length))
    }

    // MARK: - Blockquotes (consecutive lines merge into one block)

    @Test("Consecutive blockquote lines merge into one block")
    func blockquoteMergedBlock() {
        let text = "> line1\n> line2\n> line3"
        let blocks = BlockParser.parse(text)
        #expect(blocks.count == 1)
        #expect(blocks[0].content == "> line1\n> line2\n> line3")
    }

    @Test("A blockquote lazily continues a following bare line")
    func blockquoteBetweenParagraphs() {
        let text = "above\n> line1\n> line2\nbelow"
        let blocks = BlockParser.parse(text)
        // `below` lacks `>` but lazily continues the quote's paragraph (CommonMark).
        #expect(blocks.count == 2)
        #expect(blocks[0].content == "above")
        #expect(blocks[1].content == "> line1\n> line2\nbelow")
    }

    @Test("Single blockquote line is one block")
    func singleBlockquoteLine() {
        let text = "> just one"
        let blocks = BlockParser.parse(text)
        #expect(blocks.count == 1)
        #expect(blocks[0].content == "> just one")
    }

    @Test("A merged blockquote's range spans all its lines")
    func blockquoteRange() {
        let text = "> a\n> b"
        let blocks = BlockParser.parse(text)
        #expect(blocks.count == 1)
        #expect(blocks[0].range == NSRange(location: 0, length: 7))
    }

    @Test("A bare line then `> second` all lazily continue one quote (GFM ex. 228)")
    func nonConsecutiveBlockquotes() {
        let text = "> first\nparagraph\n> second"
        let blocks = BlockParser.parse(text)
        // No blank line separates them, so `paragraph` lazily continues the
        // quote and `> second` continues the same still-open paragraph.
        #expect(blocks.count == 1)
        #expect(blocks[0].content == "> first\nparagraph\n> second")
    }

    // MARK: - Changed Window (parseWithDiff)

    @Test("Unchanged re-parse yields an empty window")
    func diffUnchanged() {
        let (b1, _) = BlockParser.parseWithDiff("a\nb\nc")
        let (b2, changed) = BlockParser.parseWithDiff("a\nb\nc", previous: b1)
        #expect(changed.isEmpty)
        #expect(b1.map(\.id) == b2.map(\.id))
    }

    @Test("Editing one block yields a one-block window")
    func diffSingleEdit() {
        let (b1, _) = BlockParser.parseWithDiff("a\nb\nc")
        let (b2, changed) = BlockParser.parseWithDiff("a\nbX\nc", previous: b1)
        #expect(changed == 1..<2)
        #expect(b2[0].id == b1[0].id)
        #expect(b2[2].id == b1[2].id)
        #expect(b2[1].id != b1[1].id)
    }

    @Test("Splitting a block yields a two-block window (count change)")
    func diffSplit() {
        let (b1, _) = BlockParser.parseWithDiff("hello world\ntail")
        let (b2, changed) = BlockParser.parseWithDiff("hello\nworld\ntail", previous: b1)
        #expect(b2.count == 3)
        #expect(changed == 0..<2)
        #expect(b2[2].id == b1[1].id)   // suffix keeps its ID
    }

    @Test("Deleting a blank merges a paragraph into the quote (lazy continuation)")
    func diffMerge() {
        let (b1, _) = BlockParser.parseWithDiff("> a\n\ntail")   // quote, blank, paragraph
        #expect(b1.count == 3)
        // Removing the blank lets `tail` lazily continue the quote's paragraph.
        let (b2, _) = BlockParser.parseWithDiff("> a\ntail", previous: b1)
        #expect(b2.count == 1)
        #expect(b2[0].content == "> a\ntail")
        #expect(b2[0].kind == .quoteRun(isCallout: false))
    }

    @Test("Identical-content documents: window covers only the edit")
    func diffIdenticalContent() {
        let (b1, _) = BlockParser.parseWithDiff("a\na\na\na")
        let (b2, changed) = BlockParser.parseWithDiff("a\nX\na\na", previous: b1)
        #expect(changed == 1..<2)
        // Prefix and suffix matches keep their IDs positionally.
        #expect(b2[0].id == b1[0].id)
        #expect(b2[2].id == b1[2].id)
        #expect(b2[3].id == b1[3].id)
    }

    @Test("Overlap clamp: duplicating a block doesn't double-match")
    func diffOverlapClamp() {
        let (b1, _) = BlockParser.parseWithDiff("a")
        let (b2, changed) = BlockParser.parseWithDiff("a\na", previous: b1)
        #expect(b2.count == 2)
        #expect(changed.count == 1)
        #expect(Set(b2.map(\.id)).count == 2)
    }

    // MARK: - Block Kinds

    @Test("Kinds are classified per block")
    func kinds() {
        let text = """
        # Title
        plain
        - item
        3. ordered
        ---
        > quote

        > [!note]
        > body
        | a | b |
        | --- | --- |
        ```
        code
        ```
        $$
        x
        $$
        """
        let blocks = BlockParser.parse(text)
        let kinds = blocks.map(\.kind)
        #expect(kinds == [
            .heading(level: 1),
            .paragraph,
            .listItem,
            .listItem,
            .thematicBreak,
            .quoteRun(isCallout: false),
            .blank,
            .quoteRun(isCallout: true),
            .table,
            .fence,
            .mathDisplay,
        ])
    }

    @Test("Blank and whitespace-only lines are .blank")
    func blankKinds() {
        let blocks = BlockParser.parse("a\n\n   \nb")
        #expect(blocks.map(\.kind) == [.paragraph, .blank, .blank, .paragraph])
    }

    @Test("Thematic break beats list classification for '- - -'")
    func hrBeatsList() {
        let blocks = BlockParser.parse("- - -")
        #expect(blocks[0].kind == .thematicBreak)
    }

    // MARK: - Setext headings

    @Test("Paragraph + === underline merges into an h1 block")
    func setextH1() {
        let blocks = BlockParser.parse("Title\n===\nbody")
        #expect(blocks.count == 2)
        #expect(blocks[0].content == "Title\n===")
        #expect(blocks[0].kind == .heading(level: 1))
        #expect(blocks[1].content == "body")
    }

    @Test("Paragraph + --- underline merges into an h2 block (setext beats rule)")
    func setextH2() {
        let blocks = BlockParser.parse("Title\n---")
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .heading(level: 2))
    }

    @Test("A setext underline merges the whole preceding paragraph run (GFM Example 51)")
    func setextMultiLineContent() {
        let blocks = BlockParser.parse("Foo\nbar\n---")
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .heading(level: 2))
        #expect(blocks[0].content == "Foo\nbar\n---")
    }

    @Test("Without an underline, each paragraph line stays its own block")
    func noUnderlineKeepsPerLineBlocks() {
        let blocks = BlockParser.parse("Foo\nbar")
        #expect(blocks.map(\.kind) == [.paragraph, .paragraph])
        #expect(blocks[0].content == "Foo")
        #expect(blocks[1].content == "bar")
    }

    @Test("A setext run doesn't swallow a preceding non-paragraph block")
    func setextRunStopsAtHeading() {
        let blocks = BlockParser.parse("# h\nFoo\n===")
        #expect(blocks.map(\.kind) == [.heading(level: 1), .heading(level: 1)])
        #expect(blocks[1].content == "Foo\n===")
    }

    @Test("--- after a blank line stays a thematic break")
    func ruleAfterBlank() {
        let blocks = BlockParser.parse("para\n\n---")
        #expect(blocks.map(\.kind) == [.paragraph, .blank, .thematicBreak])
    }

    @Test("--- after a list item stays a thematic break")
    func ruleAfterList() {
        let blocks = BlockParser.parse("- item\n---")
        #expect(blocks.map(\.kind) == [.listItem, .thematicBreak])
    }

    @Test("Spaced '- - -' after a paragraph is not a setext underline")
    func spacedRuleNotUnderline() {
        let blocks = BlockParser.parse("para\n- - -")
        #expect(blocks.map(\.kind) == [.paragraph, .thematicBreak])
    }

    @Test("Underline with trailing non-space text is not a setext underline")
    func underlineWithTrailingText() {
        let blocks = BlockParser.parse("para\n=== x")
        #expect(blocks.map(\.kind) == [.paragraph, .paragraph])
    }

    @Test("Setext underline can't follow a heading or blank line")
    func underlineNeedsParagraph() {
        let blocks = BlockParser.parse("# h\n===")
        #expect(blocks.map(\.kind) == [.heading(level: 1), .paragraph])
    }

    // MARK: - Indented code blocks

    @Test("A run of 4-space lines at document start merges into one code block")
    func indentedCodeRun() {
        let blocks = BlockParser.parse("    a\n    b")
        #expect(blocks.count == 1)
        #expect(blocks[0].content == "    a\n    b")
        #expect(blocks[0].kind == .indentedCode)
    }

    @Test("Tab indentation opens a code block")
    func tabIndentedCode() {
        let blocks = BlockParser.parse("\tcode")
        #expect(blocks.map(\.kind) == [.indentedCode])
    }

    @Test("Indented code needs a preceding blank line")
    func indentedCodeNeedsBlank() {
        let blocks = BlockParser.parse("foo\n    bar")
        #expect(blocks.map(\.kind) == [.paragraph, .paragraph])
    }

    @Test("Indented run after a blank line is a code block")
    func indentedCodeAfterBlank() {
        let blocks = BlockParser.parse("foo\n\n    bar")
        #expect(blocks.map(\.kind) == [.paragraph, .blank, .indentedCode])
    }

    @Test("An interior blank line stays inside the code block (GFM Example 82)")
    func indentedCodeBlankSplits() {
        let blocks = BlockParser.parse("    a\n\n    b")
        #expect(blocks.map(\.kind) == [.indentedCode])
        #expect(blocks[0].content == "    a\n\n    b")
    }

    @Test("A blank line before non-code content is not swallowed into the code block")
    func indentedCodeTrailingBlankNotSwallowed() {
        let blocks = BlockParser.parse("    a\n\nx")
        #expect(blocks.map(\.kind) == [.indentedCode, .blank, .paragraph])
        #expect(blocks[0].content == "    a")
    }

    @Test("Multiple interior blank lines and chunks all stay in one code block")
    func indentedCodeMultipleInteriorBlanks() {
        let blocks = BlockParser.parse("    a\n\n\n    b\n\npara")
        #expect(blocks.map(\.kind) == [.indentedCode, .blank, .paragraph])
        #expect(blocks[0].content == "    a\n\n\n    b")
    }

    @Test("A deeply indented list item is rescued as a list, not code")
    func indentedListBeatsCode() {
        let blocks = BlockParser.parse("    - item")
        #expect(blocks.map(\.kind) == [.listItem])
    }

    @Test("An indented line followed by a setext-ish underline stays code + rule")
    func indentedCodeNotSetext() {
        let blocks = BlockParser.parse("    code\n---")
        #expect(blocks.map(\.kind) == [.indentedCode, .thematicBreak])
    }
}

// GFM §4.6: the seven HTML-block start conditions and their end conditions.
@Suite("BlockParser — HTML blocks")
struct BlockParserHTMLBlockTests {

    @Test("Type 6 block tag runs to the blank line")
    func type6() {
        let blocks = BlockParser.parse("<div>\n*foo*\n</div>\n\npara")
        #expect(blocks.map(\.kind) == [.htmlBlock, .blank, .paragraph])
        #expect(blocks[0].content == "<div>\n*foo*\n</div>")
    }

    @Test("Type 6 unterminated runs to EOF")
    func type6EOF() {
        let blocks = BlockParser.parse("<div>\n*foo*")
        #expect(blocks.map(\.kind) == [.htmlBlock])
    }

    @Test("Type 6 interrupts a paragraph")
    func type6Interrupts() {
        let blocks = BlockParser.parse("para\n<div>\nx")
        #expect(blocks.map(\.kind) == [.paragraph, .htmlBlock])
    }

    @Test("Type 1 <script> ends ON the </script> line")
    func type1() {
        let blocks = BlockParser.parse("<script>\nalert(1)\n</script>\nafter")
        #expect(blocks.map(\.kind) == [.htmlBlock, .paragraph])
        #expect(blocks[0].content == "<script>\nalert(1)\n</script>")
    }

    @Test("Type 1 end condition can be on the start line")
    func type1OneLine() {
        let blocks = BlockParser.parse("<pre role=\"x\">y</pre>")
        #expect(blocks.map(\.kind) == [.htmlBlock])
    }

    @Test("Types 2–5: comment, PI, declaration, CDATA")
    func types2to5() {
        let comment = BlockParser.parse("<!--\nnote\n-->\nok")
        #expect(comment.map(\.kind) == [.htmlBlock, .paragraph])
        #expect(comment[0].content == "<!--\nnote\n-->")
        #expect(BlockParser.parse("<?php\necho\n?>").map(\.kind) == [.htmlBlock])
        #expect(BlockParser.parse("<!DOCTYPE html>").map(\.kind) == [.htmlBlock])
        #expect(BlockParser.parse("<![CDATA[\ndata\n]]>").map(\.kind) == [.htmlBlock])
    }

    @Test("Type 2 unterminated comment runs to EOF")
    func type2EOF() {
        #expect(BlockParser.parse("<!-- open\nrest\nmore").map(\.kind) == [.htmlBlock])
    }

    @Test("Type 7 lone complete tag after a blank line")
    func type7() {
        let blocks = BlockParser.parse("para\n\n<custom-tag attr='x'>\ncontent")
        #expect(blocks.map(\.kind) == [.paragraph, .blank, .htmlBlock])
        #expect(blocks[2].content == "<custom-tag attr='x'>\ncontent")
    }

    @Test("Type 7 cannot interrupt a paragraph")
    func type7NoInterrupt() {
        #expect(BlockParser.parse("para\n<custom-tag>").map(\.kind) == [.paragraph, .paragraph])
    }

    @Test("A 4-space-indented tag is indented code, not an HTML block")
    func indentedNotHTML() {
        #expect(BlockParser.parse("    <div>").map(\.kind) == [.indentedCode])
    }

    @Test("An HTML start under a paragraph isn't swallowed as setext content")
    func setextDoesNotSwallowHTML() {
        let blocks = BlockParser.parse("Foo\n<div>\n---")
        #expect(blocks.map(\.kind) == [.paragraph, .htmlBlock])
        #expect(blocks[1].content == "<div>\n---")
    }
}

@Suite("BlockParser — performance guards")
struct BlockParserPerfTests {

    /// The multi-line setext scan is memoized (LineBuffer.noSetextUnderlineBefore):
    /// without the memo, a long blank-line-free paragraph run makes the parse
    /// quadratic (every line re-scans to the run's end — a 20k-line document
    /// took >10 minutes). The generous bound only trips on complexity bugs,
    /// not slow CI machines.
    @Test("A 10k-line blank-line-free paragraph run parses in linear-ish time")
    func hugeParagraphRun() {
        let doc = Array(repeating: "just a plain prose line with words",
                        count: 10_000).joined(separator: "\n")
        let t0 = DispatchTime.now()
        let blocks = BlockParser.parse(doc)
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9
        #expect(blocks.count == 10_000)
        #expect(seconds < 10)
    }

    /// HTML-block end scans are consumed (the parser advances past them), so a
    /// huge blank-line-free type-6 block must merge in one linear pass.
    @Test("A 10k-line HTML block parses in linear-ish time")
    func hugeHTMLBlockRun() {
        let doc = Array(repeating: "<div>x</div>", count: 10_000).joined(separator: "\n")
        let t0 = DispatchTime.now()
        let blocks = BlockParser.parse(doc)
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9
        #expect(blocks.count == 1)
        #expect(seconds < 10)
    }

    /// `<custom> trailing words` opens no HTML block (name not in the type-6
    /// list; the trailing words defeat type 7), so the start check must stay
    /// O(line) across a huge run of such paragraphs.
    @Test("A 10k-line angle-bracket paragraph run parses in linear-ish time")
    func hugeAngleParagraphRun() {
        let doc = Array(repeating: "<custom> trailing words", count: 10_000).joined(separator: "\n")
        let t0 = DispatchTime.now()
        let blocks = BlockParser.parse(doc)
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9
        #expect(blocks.count == 10_000)
        #expect(seconds < 10)
    }
}
