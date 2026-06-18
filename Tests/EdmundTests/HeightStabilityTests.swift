import Testing
import AppKit
@testable import EdmundCore

/// Activating a block (moving the caret into it) reveals its raw markdown
/// markers. For most block kinds the rendered and active forms must occupy the
/// same vertical space — otherwise content below shifts the moment you click in,
/// which is the scroll "lurch" the editor has been chasing. This suite pins that
/// invariant per block kind by measuring a reference line BELOW the block: if the
/// block's height changes between rendered and active, the reference line moves.
///
/// Known/accepted exceptions (tracked in todo.md): thematic break and heading
/// legitimately change height (different font size when the `#`s appear).
@Suite("Height stability: rendered vs active")
@MainActor
struct HeightStabilityTests {

    /// Loads `block` followed by a reference paragraph, measures the reference
    /// line's Y rendered (caret elsewhere) vs active (caret in the block), and
    /// returns how far it moved. `< ~1pt` means no height change.
    private func referenceShift(forBlock block: String,
                                caretMarker: String) -> CGFloat {
        let editor = makeEditor()
        // A leading paragraph keeps the measured block off the document origin,
        // and the reference paragraph sits below it.
        let doc = "lead paragraph\n\n\(block)\n\nREFERENCE LINE\n\n"
        editor.loadContent(doc)
        ensureFullLayout(editor)

        let ns = editor.rawSource as NSString
        let refOffset = ns.range(of: "REFERENCE LINE").location
        #expect(refOffset != NSNotFound)

        // Rendered: caret in the lead paragraph, block inactive.
        let leadOffset = ns.range(of: "lead paragraph").location
        editor.setSelectedRange(NSRange(location: leadOffset, length: 0))
        editor.recomposeIncremental(cursorInRaw: leadOffset)
        ensureFullLayout(editor)
        guard let yRendered = editor.lineRect(forCharacterAt: refOffset)?.minY else {
            Issue.record("no rendered line rect"); return .greatestFiniteMagnitude
        }

        // Active: caret inside the block.
        let caretOffset = ns.range(of: caretMarker).location
        #expect(caretOffset != NSNotFound)
        editor.setSelectedRange(NSRange(location: caretOffset, length: 0))
        editor.recomposeIncremental(cursorInRaw: caretOffset)
        ensureFullLayout(editor)
        guard let yActive = editor.lineRect(forCharacterAt: refOffset)?.minY else {
            Issue.record("no active line rect"); return .greatestFiniteMagnitude
        }

        return abs(yActive - yRendered)
    }

    private let tolerance: CGFloat = 1.0

    @Test("Inline bold has no height change")
    func inlineBold() {
        #expect(referenceShift(forBlock: "A line with **bold** word.",
                               caretMarker: "bold") < tolerance)
    }

    @Test("Inline italic has no height change")
    func inlineItalic() {
        #expect(referenceShift(forBlock: "A line with *italic* word.",
                               caretMarker: "italic") < tolerance)
    }

    @Test("Inline strikethrough has no height change")
    func inlineStrikethrough() {
        #expect(referenceShift(forBlock: "A line with ~~struck~~ word.",
                               caretMarker: "struck") < tolerance)
    }

    @Test("Inline highlight has no height change")
    func inlineHighlight() {
        #expect(referenceShift(forBlock: "A line with ==marked== word.",
                               caretMarker: "marked") < tolerance)
    }

    @Test("Inline code has no height change")
    func inlineCode() {
        #expect(referenceShift(forBlock: "A line with `code` word.",
                               caretMarker: "code") < tolerance)
    }

    @Test("Inline link has no height change")
    func inlineLink() {
        #expect(referenceShift(forBlock: "A line with [text](https://e.com) word.",
                               caretMarker: "text") < tolerance)
    }

    @Test("Bulleted list item has no height change")
    func bulletedList() {
        #expect(referenceShift(forBlock: "- bullet item",
                               caretMarker: "bullet item") < tolerance)
    }

    @Test("Numbered list item has no height change")
    func numberedList() {
        #expect(referenceShift(forBlock: "1. numbered item",
                               caretMarker: "numbered item") < tolerance)
    }

    @Test("Checklist item has no height change")
    func checklist() {
        #expect(referenceShift(forBlock: "- [ ] task item",
                               caretMarker: "task item") < tolerance)
    }

    @Test("Blockquote has no height change")
    func blockquote() {
        #expect(referenceShift(forBlock: "> quoted text",
                               caretMarker: "quoted text") < tolerance)
    }

    // MARK: Wrapping cases
    //
    // The todo's real concern: revealing markers widens the active form, which
    // can tip a long line onto an extra wrapped line. These use content long
    // enough to wrap several times in the ~500pt container, with slack so the
    // marker width doesn't sit on a wrap boundary — the wrapped height must
    // still match exactly.

    @Test("Wrapping bold paragraph has no height change")
    func wrappingBold() {
        let long = "Alpha bravo charlie delta echo foxtrot golf hotel india "
            + "**juliett** kilo lima mike november oscar papa quebec romeo sierra "
            + "tango uniform victor whiskey xray yankee zulu."
        #expect(referenceShift(forBlock: long, caretMarker: "juliett") < tolerance)
    }

    @Test("Wrapping list item has no height change")
    func wrappingListItem() {
        let long = "- Alpha bravo charlie delta echo foxtrot golf hotel india "
            + "juliett kilo lima mike november oscar papa quebec romeo sierra "
            + "tango uniform victor whiskey xray yankee zulu wraps here."
        #expect(referenceShift(forBlock: long, caretMarker: "juliett") < tolerance)
    }

    @Test("Wrapping checklist item has no height change")
    func wrappingChecklist() {
        let long = "- [ ] Alpha bravo charlie delta echo foxtrot golf hotel india "
            + "juliett kilo lima mike november oscar papa quebec romeo sierra "
            + "tango uniform victor whiskey xray yankee zulu wraps here."
        #expect(referenceShift(forBlock: long, caretMarker: "juliett") < tolerance)
    }

    @Test("Heading has no height change")
    func heading() {
        // An existing heading keeps its size when activated — the `#` markers
        // appear without changing line height. (The todo's "different font size"
        // note is about the paragraph↔heading content transition of typing `#`,
        // a different scenario than this rendered↔active toggle.)
        #expect(referenceShift(forBlock: "# Big Heading",
                               caretMarker: "Big Heading") < tolerance)
    }

    @Test("Thematic break has no height change")
    func thematicBreak() {
        // The active form keeps the rendered rule's forced line height and
        // breathing space, so clicking into the `---` no longer shifts content.
        #expect(referenceShift(forBlock: "---", caretMarker: "---") < tolerance)
    }

    // MARK: Discriminator — keeps the all-green suite honest
    //
    // todo.md excludes math from the zero-change requirement ("Inline items
    // (except math)"): display math renders as an image when inactive and as
    // raw multi-line LaTeX when active, so it legitimately changes height.
    // Asserting it DOES shift proves the harness can still detect a real height
    // change — otherwise a `referenceShift` that always returned 0 would pass
    // every test above vacuously.

    @Test("Display math changes height (excluded from zero-change)")
    func displayMathChangesHeight() {
        let shift = referenceShift(forBlock: "$$\ne = mc^2\n$$", caretMarker: "mc^2")
        #expect(shift > tolerance, "expected a height change, got \(shift)")
    }
}
