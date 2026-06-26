import Testing
import AppKit
@testable import EdmundCore

/// Regression tests for the "delete drift" bug. A stranded marked-text (IME /
/// accent / emoji) composition makes `didChangeText` bail before
/// `syncRawSourceFromDisplay()`, so the text storage mutates while
/// `rawSource`/`blocks` freeze — breaking the storage==rawSource invariant.
/// From then on every edit does offset math against a stale model and the caret
/// drifts. Two defenses:
///   1. The async active-block restyle never recomposes during composition
///      (so it can't strand the marked text in the first place).
///   2. Regaining first responder resyncs if the invariant is broken
///      (a catch-all recovery for any other stranding path).
@Suite("Marked-text desync (delete drift)") @MainActor
struct MarkedTextDesyncTests {

    /// Sanity: setting marked text breaks the invariant (this is the transient
    /// state during composition); it is *stranding* that turns it into a bug.
    @Test func markedTextBreaksInvariantTransiently() {
        let editor = makeEditor()
        editor.loadContent("alpha\nbravo\ncharlie")
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        #expect(editor.textStorage!.string == editor.rawSource)

        editor.setMarkedText("´", selectedRange: NSRange(location: 0, length: 1),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        #expect(editor.textStorage!.string != editor.rawSource)   // storage ahead
    }

    /// Recovery: once a composition is stranded (storage drifted from
    /// rawSource), regaining first responder must restore the invariant and a
    /// styled, parseable model. Without the recovery hook the editor stays
    /// desynced and every delete drifts.
    @Test func regainingFocusRecoversStrandedComposition() {
        let editor = makeEditor()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                           styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = editor
        win.makeFirstResponder(editor)

        editor.loadContent("alpha\nbravo\ncharlie")
        editor.setSelectedRange(NSRange(location: 5, length: 0))

        // Strand a composition: storage gains "´", rawSource frozen.
        editor.setMarkedText("´", selectedRange: NSRange(location: 0, length: 1),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.textStorage!.string != editor.rawSource)

        // Leave the editor and come back (what the user does to unstick it).
        win.makeFirstResponder(nil)
        win.makeFirstResponder(editor)

        // Invariant restored, no stranded marked text, model reflects storage.
        #expect(!editor.hasMarkedText())
        #expect(editor.textStorage!.string == editor.rawSource)
        let joined = editor.blocks.map(\.content).joined(separator: "\n")
        #expect(joined == editor.rawSource)

        // A normal backspace now deletes exactly one character (no drift).
        let before = (editor.rawSource as NSString).length
        editor.setSelectedRange(NSRange(location: before, length: 0))
        pressBackspace(in: editor)
        #expect((editor.rawSource as NSString).length == before - 1)
        #expect(editor.textStorage!.string == editor.rawSource)
    }
}
