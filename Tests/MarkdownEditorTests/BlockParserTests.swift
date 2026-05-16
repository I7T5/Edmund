import Testing
import Foundation
@testable import MarkdownEditorCore

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

    @Test("Code fence range covers full text")
    func codeFenceRange() {
        let text = "```\nhello\n```"
        let blocks = BlockParser.parse(text)
        #expect(blocks[0].range == NSRange(location: 0, length: (text as NSString).length))
    }
}
