import Testing
import AppKit
@testable import EdmundCore

/// Regression tests for the round-4 "delete drift" (issue #156): AppKit's
/// drag-move source deletion runs shouldChangeText → replaceCharacters but
/// never calls didChangeText, so rawSource/blocks silently freeze. Every later
/// edit then does offset math against the stale model (the caret leap) and
/// autosave writes the stale rawSource. The fix schedules a check from
/// shouldChangeText: a pendingEdit still unconsumed on the next run-loop pass
/// means didChangeText was bypassed, and the editor heals by running the sync
/// didChangeText would have run.
@Suite("didChangeText-bypass heal (delete drift round 4)") @MainActor
struct BypassedEditSyncTests {

    /// An edit that goes through shouldChangeText but never didChangeText —
    /// the drag-move source deletion — must be healed on the next run-loop
    /// pass, restoring storage == rawSource and a parseable model.
    @Test func editBypassingDidChangeTextHeals() {
        let editor = makeEditor()
        editor.loadContent("alpha\nbravo\ncharlie")
        editor.setSelectedRange(NSRange(location: 11, length: 0))

        // Simulate AppKit's bypass: shouldChangeText, storage mutation, and
        // no closing didChangeText.
        let dragged = NSRange(location: 6, length: 5)   // "bravo"
        #expect(editor.shouldChangeText(in: dragged, replacementString: ""))
        editor.textStorage!.replaceCharacters(in: dragged, with: "")

        // Desync is live: storage moved, model frozen.
        #expect(editor.textStorage!.string != editor.rawSource)

        // The scheduled check fires on the next main-run-loop pass and heals.
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        #expect(editor.textStorage!.string == editor.rawSource)
        let joined = editor.blocks.map(\.content).joined(separator: "\n")
        #expect(joined == editor.rawSource)

        // A normal backspace now deletes exactly one character — no drift.
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        pressBackspace(in: editor)
        #expect(editor.rawSource == "alph\n\ncharlie")
        #expect(editor.textStorage!.string == editor.rawSource)
    }

    /// When the bypassed deletion removes the selected text itself (the log's
    /// {951,37} case), the stale selection spans past the new document end.
    /// The heal must collapse it to the edit point — otherwise the restyle's
    /// layout invalidation makes AppKit clamp the caret to the end of the
    /// document (the round-5 leap).
    @Test func healRepairsSelectionSpanningDeletedText() {
        let editor = makeEditor()
        editor.loadContent("alpha\nbravo\ncharlie")
        let dragged = NSRange(location: 12, length: 7)   // "charlie"
        editor.setSelectedRange(dragged)

        #expect(editor.shouldChangeText(in: dragged, replacementString: ""))
        editor.textStorage!.replaceCharacters(in: dragged, with: "")

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        #expect(editor.textStorage!.string == editor.rawSource)
        #expect(editor.selectedRange() == NSRange(location: 12, length: 0))

        // Backspace deletes exactly the character before the edit point.
        pressBackspace(in: editor)
        #expect(editor.rawSource == "alpha\nbravo")
        #expect(editor.selectedRange() == NSRange(location: 11, length: 0))
    }

    /// The check must NOT fire during a live IME composition: there the
    /// unconsumed pendingEdit is legitimate and didChangeText syncs on commit.
    @Test func healSkipsLiveComposition() {
        let editor = makeEditor()
        editor.loadContent("alpha\nbravo\ncharlie")
        editor.setSelectedRange(NSRange(location: 5, length: 0))

        editor.setMarkedText("´", selectedRange: NSRange(location: 0, length: 1),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        #expect(editor.textStorage!.string != editor.rawSource)   // transient

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        // Still composing: the heal must not have recomposed the marked text
        // away or force-synced mid-composition.
        #expect(editor.hasMarkedText())
        #expect(editor.textStorage!.string != editor.rawSource)
    }
}
