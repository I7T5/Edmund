import Testing
import AppKit
@testable import EdmundCore

// MARK: - Auto-closing brackets and quotes (Settings ▸ Edit ▸ Editing)

@Suite("EditorTextView — Auto Pairs")
struct EditorTextViewAutoPairTests {

    /// Type one character at `location` the way NSTextView's key handling would.
    @MainActor private func type(_ text: String, at location: Int, in editor: EditorTextView) {
        editor.setSelectedRange(NSRange(location: location, length: 0))
        editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    @Test("Opening bracket inserts its partner and leaves the caret between")
    @MainActor func insertsPartner() {
        let editor = makeEditor()
        editor.loadContent("")
        type("(", at: 0, in: editor)
        #expect(editor.rawSource == "()")
        #expect(editor.selectedRange() == NSRange(location: 1, length: 0))
    }

    @Test("Every configured pair closes")
    @MainActor func allPairs() {
        for (open, expected) in [("(", "()"), ("[", "[]"), ("{", "{}"),
                                 ("\"", "\"\""), ("'", "''"), ("`", "``")] {
            let editor = makeEditor()
            editor.loadContent("")
            type(open, at: 0, in: editor)
            #expect(editor.rawSource == expected)
        }
    }

    @Test("Typing the closer where one already sits steps over it")
    @MainActor func typesOverCloser() {
        let editor = makeEditor()
        editor.loadContent("")
        type("(", at: 0, in: editor)
        editor.insertText(")", replacementRange: NSRange(location: NSNotFound, length: 0))
        // Stepped over the existing ")" instead of inserting a second one.
        #expect(editor.rawSource == "()")
        #expect(editor.selectedRange() == NSRange(location: 2, length: 0))
    }

    @Test("Apostrophe after a word stays a lone apostrophe")
    @MainActor func apostropheInWord() {
        let editor = makeEditor()
        editor.loadContent("don")
        type("'", at: 3, in: editor)
        #expect(editor.rawSource == "don'")
    }

    @Test("No partner is inserted directly before a word")
    @MainActor func noPartnerBeforeWord() {
        let editor = makeEditor()
        editor.loadContent("word")
        type("(", at: 0, in: editor)
        #expect(editor.rawSource == "(word")
    }

    @Test("A bracket before punctuation still pairs")
    @MainActor func pairsBeforePunctuation() {
        let editor = makeEditor()
        editor.loadContent(".")
        type("(", at: 0, in: editor)
        #expect(editor.rawSource == "().")
    }

    @Test("Disabled: typing an opening bracket inserts only that character")
    @MainActor func disabledInsertsPlainCharacter() {
        let editor = makeEditor()
        editor.autoCloseBracketsEnabled = false
        editor.loadContent("")
        type("(", at: 0, in: editor)
        #expect(editor.rawSource == "(")
    }

    @Test("Disabled: the closer is not typed over")
    @MainActor func disabledDoesNotTypeOver() {
        let editor = makeEditor()
        editor.autoCloseBracketsEnabled = false
        editor.loadContent(")")
        type(")", at: 0, in: editor)
        #expect(editor.rawSource == "))")
    }

    @Test("Multi-character insertions are untouched")
    @MainActor func multiCharacterInsertUntouched() {
        let editor = makeEditor()
        editor.loadContent("")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText("(paste)", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.rawSource == "(paste)")
    }

    // MARK: - Deleting the opener takes the adjacent closer with it

    @Test("Deleting an opening bracket removes the adjacent closer")
    @MainActor func deleteRemovesAdjacentCloser() {
        let editor = makeEditor()
        editor.loadContent("")
        type("(", at: 0, in: editor)
        editor.deleteBackward(nil)
        #expect(editor.rawSource == "")
        #expect(editor.selectedRange() == NSRange(location: 0, length: 0))
    }

    @Test("Every pair deletes as a pair")
    @MainActor func deleteAllPairs() {
        for text in ["()", "[]", "{}", "\"\"", "''", "``"] {
            let editor = makeEditor()
            editor.loadContent("a" + text + "b")
            editor.setSelectedRange(NSRange(location: 2, length: 0))
            editor.deleteBackward(nil)
            #expect(editor.rawSource == "ab")
        }
    }

    @Test("A separated pair deletes only the opener")
    @MainActor func deleteSeparatedPair() {
        let editor = makeEditor()
        editor.loadContent("(x)")
        editor.setSelectedRange(NSRange(location: 1, length: 0))
        editor.deleteBackward(nil)
        #expect(editor.rawSource == "x)")
    }

    @Test("Deleting the closer leaves the opener alone")
    @MainActor func deleteCloserOnly() {
        let editor = makeEditor()
        editor.loadContent("()")
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        editor.deleteBackward(nil)
        #expect(editor.rawSource == "(")
    }

    @Test("A selected range still deletes only the selection")
    @MainActor func deleteSelectionUntouched() {
        let editor = makeEditor()
        editor.loadContent("a()b")
        editor.setSelectedRange(NSRange(location: 0, length: 2))
        editor.deleteBackward(nil)
        #expect(editor.rawSource == ")b")
    }

    @Test("The pair delete undoes in one step")
    @MainActor func deleteUndoesAsOne() {
        let editor = makeEditor()
        editor.loadContent("a()b")
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        editor.deleteBackward(nil)
        #expect(editor.rawSource == "ab")
        editor.performUndo()
        #expect(editor.rawSource == "a()b")
    }

    @Test("Disabled: deleting an opener leaves the closer")
    @MainActor func disabledDeleteLeavesCloser() {
        let editor = makeEditor()
        editor.autoCloseBracketsEnabled = false
        editor.loadContent("()")
        editor.setSelectedRange(NSRange(location: 1, length: 0))
        editor.deleteBackward(nil)
        #expect(editor.rawSource == ")")
    }

    @Test("Replacing a selection does not auto-close")
    @MainActor func selectionReplacementUntouched() {
        let editor = makeEditor()
        editor.loadContent("abc")
        editor.setSelectedRange(NSRange(location: 0, length: 3))
        editor.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.rawSource == "(")
    }
}

// MARK: - Quick format: a delimiter key wraps the selection

@Suite("EditorTextView — Wrap selection on delimiter key")
struct EditorTextViewWrapSelectionTests {

    @MainActor private func typeOverSelection(_ text: String, _ range: NSRange,
                                              in editor: EditorTextView) {
        editor.setSelectedRange(range)
        editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    @Test("Each delimiter wraps the selection and keeps the inner text selected")
    @MainActor func wrapsAndReselects() {
        for delimiter in ["$", "*", "%", "=", "~", "`"] {
            let editor = makeEditor()
            editor.loadContent("say word now")
            typeOverSelection(delimiter, NSRange(location: 4, length: 4), in: editor)
            #expect(editor.rawSource == "say \(delimiter)word\(delimiter) now")
            #expect(editor.selectedRange() == NSRange(location: 5, length: 4))
        }
    }

    @Test("Typing the key again doubles the delimiter — bold, highlight, strike")
    @MainActor func secondPressDoubles() {
        let editor = makeEditor()
        editor.loadContent("word")
        typeOverSelection("*", NSRange(location: 0, length: 4), in: editor)
        editor.insertText("*", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.rawSource == "**word**")
        #expect(editor.selectedRange() == NSRange(location: 2, length: 4))
    }

    @Test("Without a selection the key types as usual")
    @MainActor func caretTypesTheCharacter() {
        let editor = makeEditor()
        editor.loadContent("ab")
        typeOverSelection("*", NSRange(location: 1, length: 0), in: editor)
        #expect(editor.rawSource == "a*b")
    }

    @Test("Other keys still replace the selection")
    @MainActor func otherKeysReplace() {
        let editor = makeEditor()
        editor.loadContent("word")
        typeOverSelection("x", NSRange(location: 0, length: 4), in: editor)
        #expect(editor.rawSource == "x")
    }

    @Test("The wrap is one undo step")
    @MainActor func undoRestores() {
        let editor = makeEditor()
        editor.loadContent("word")
        typeOverSelection("=", NSRange(location: 0, length: 4), in: editor)
        #expect(editor.rawSource == "=word=")
        editor.undo(nil)
        #expect(editor.rawSource == "word")
    }
}
