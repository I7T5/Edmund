import Testing
import AppKit
@testable import MarkdownEditorCore

/// Seeded random edits through the full editor pipeline. In DEBUG builds
/// every edit also runs the incremental-vs-full parse assertion inside
/// syncRawSourceFromDisplay, so this doubles as the incremental parser's
/// fuzz net; the oracle assertion here checks the styled storage too.
@Suite("Incremental parse — fuzz")
struct IncrementalParseFuzzTests {

    @Test("Random edits keep blocks and styling equivalent to a full parse",
          arguments: [UInt64(1), 7, 1234, 0xBEEF])
    @MainActor func randomEdits(seed: UInt64) {
        var rng = SeededGenerator(seed: seed)
        let editor = makeEditor()
        editor.loadContent(makeLargeMarkdown(approximateBytes: 6_000, seed: seed))

        // Fragments biased toward structure-changing characters.
        let fragments = ["\n", "\n\n", "```", "```\n", "$$", "|", ">", "> ",
                         "# ", "- ", "---\n", "x", "hello **world**",
                         "| a | b |", "[!note]"]

        for _ in 0..<120 {
            let ns = editor.rawSource as NSString
            let len = ns.length
            switch Int.random(in: 0..<10, using: &rng) {
            case 0..<5:   // insert a fragment somewhere (edges included)
                let loc = Int.random(in: 0...len, using: &rng)
                let frag = fragments.randomElement(using: &rng)!
                editor.setSelectedRange(NSRange(location: loc, length: 0))
                editor.insertText(frag, replacementRange: NSRange(location: loc, length: 0))
            case 5..<8 where len > 0:   // delete a span (possibly multi-block)
                let loc = Int.random(in: 0..<len, using: &rng)
                let span = min(Int.random(in: 1...40, using: &rng), len - loc)
                editor.setSelectedRange(NSRange(location: loc, length: span))
                editor.insertText("", replacementRange: NSRange(location: loc, length: span))
            case 8 where len > 0:       // replace a span with a fragment
                let loc = Int.random(in: 0..<len, using: &rng)
                let span = min(Int.random(in: 1...20, using: &rng), len - loc)
                let frag = fragments.randomElement(using: &rng)!
                editor.setSelectedRange(NSRange(location: loc, length: span))
                editor.insertText(frag, replacementRange: NSRange(location: loc, length: span))
            default:                    // undo occasionally
                editor.performUndo()
            }

            // Ranges must tile the document after every edit.
            let total = (editor.rawSource as NSString).length
            if let last = editor.blocks.last {
                #expect(last.range.upperBound <= total)
            }
        }

        // Converged storage must match the styling oracle.
        assertMatchesFullRecomposeOracle(editor, "after fuzz (seed \(seed))")
    }
}
