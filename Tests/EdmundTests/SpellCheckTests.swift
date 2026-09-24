import Testing
import AppKit
@testable import EdmundCore

@Suite("Spell check")
@MainActor
struct SpellCheckTests {

    /// The text under each spelling mark TextKit 2 is drawing.
    private func marked(_ editor: EditorTextView) -> [String] {
        guard let tlm = editor.textLayoutManager else { return [] }
        var words: [String] = []
        tlm.enumerateRenderingAttributes(from: tlm.documentRange.location, reverse: false) { tlm, attrs, range in
            if attrs[.spellingState] != nil {
                let start = tlm.offset(from: tlm.documentRange.location, to: range.location)
                let len = tlm.offset(from: range.location, to: range.endLocation)
                words.append((editor.string as NSString).substring(with: NSRange(location: start, length: len)))
            }
            return true
        }
        return words
    }

    private func checkedEditor(_ text: String) -> EditorTextView {
        let editor = makeEditor()
        editor.loadContent(text)
        editor.isContinuousSpellCheckingEnabled = true
        editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        editor.recheckSpelling(blocks: IndexSet(editor.blocks.indices))
        return editor
    }

    @Test("A misspelled word is marked")
    func marksMisspelling() {
        #expect(marked(checkedEditor("This is a sentance.\n")) == ["sentance"])
    }

    @Test("An inline enumeration isn't one misspelled word")
    func enumerationIsSplit() {
        let editor = checkedEditor("Choose a,b,c or x;y;z, and i,ii,iii.\n")
        #expect(marked(editor) == [])
    }

    @Test("A misspelled part of an enumeration is still marked, alone")
    func enumerationKeepsMisspelledPart() {
        #expect(marked(checkedEditor("Pick a,b,zzq now.\n")) == ["zzq"])
    }

    @Test("A missing space between real words stays flagged whole")
    func missingSpaceStaysFlagged() {
        #expect(marked(checkedEditor("Say Hello,world now.\n")) == ["Hello,world"])
    }

    @Test("LaTeX in inline and display math is skipped")
    func mathSkipped() {
        let editor = checkedEditor("Inline $\\mathrm{dx}$ sentance.\n\n$$\n\\mathrm{dy} \\operatorname{wrod}\n$$\n")
        #expect(marked(editor) == ["sentance"])
    }

    @Test("Fixing a misspelled word clears its mark (no stale split mark)")
    func fixClearsMark() {
        let editor = checkedEditor("Helo world\n\nend\n")
        #expect(marked(editor) == ["Helo"])
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        editor.insertText("l", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.string.hasPrefix("Hello world"))
        #expect(marked(editor) == [])
    }

    @Test("A new misspelling typed mid-document is marked once the caret leaves it")
    func newMisspellingMarked() {
        let editor = checkedEditor("One two\n\nend\n")
        editor.setSelectedRange(NSRange(location: 7, length: 0))
        editor.insertText(" wrod", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(marked(editor) == [])            // still typing it
        editor.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(marked(editor) == ["wrod"])
    }

    @Test("A misspelled word under the caret is marked when nothing is being typed")
    func caretWordMarkedOutsideEdits() {
        let editor = checkedEditor("Helo world\n")
        editor.setSelectedRange(NSRange(location: 0, length: 0))   // e.g. just opened
        editor.recheckSpelling(blocks: IndexSet(editor.blocks.indices))
        #expect(marked(editor) == ["Helo"])
    }

    @Test("Clicking into a misspelled word keeps its mark, from another block or the same one")
    func clickKeepsMark() {
        let editor = checkedEditor("Helo world\n\nend\n")
        editor.setSelectedRange(NSRange(location: 2, length: 0))   // from the `end` block
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))    // the async cross-block restyle
        #expect(marked(editor) == ["Helo"])
        editor.setSelectedRange(NSRange(location: 7, length: 0))   // within the block
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        #expect(marked(editor) == ["Helo"])
    }

    @Test("The grammar issue in the sentence being typed is spared")
    func grammarSparedAtCaret() {
        let editor = checkedEditor("One two three.\n")
        let issue = NSTextCheckingResult.grammarCheckingResult(
            range: NSRange(location: 0, length: 14),
            details: [[NSGrammarRange: NSRange(location: 4, length: 3)]])
        #expect(editor.filteredCheckingResults([issue], orthography: nil, sparing: 10).isEmpty)
        #expect(editor.filteredCheckingResults([issue], orthography: nil, sparing: nil).count == 1)
    }

    @Test("Check Document Now steps past math and fine enumerations")
    func panelSkipsFiltered() {
        let editor = checkedEditor("See $\\mathrm{dx}$ and a,b,c then sentance.\n")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.checkSpelling(nil)
        let sel = editor.selectedRange()
        #expect((editor.string as NSString).substring(with: sel) == "sentance")
    }
}
