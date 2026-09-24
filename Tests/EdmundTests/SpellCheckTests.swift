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
        #expect(marked(checkedEditor("Pick a,helo,c now.\n")) == ["helo"])
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
}
