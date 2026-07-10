import Testing
import AppKit
@testable import EdmundCore

// Nested plain block quotes: each `>` level gets its own span (depth-tagged),
// its own hidden marker, and its own left bar stacked with its ancestors' —
// outermost bar leftmost, deepest adjacent to the text. Other nested block
// constructs stay literal (covered by NestedBlockStylingTests).

private func decorationList(at offset: Int, in s: NSAttributedString) -> BlockDecorationList? {
    guard offset < s.length else { return nil }
    return s.attribute(.blockDecoration, at: offset, effectiveRange: nil) as? BlockDecorationList
}

private func barInsets(_ deco: Any?) -> [CGFloat] {
    func inset(_ d: BlockDecoration) -> CGFloat? {
        guard case .leftBar = d.kind else { return nil }
        return d.inset
    }
    if let list = deco as? BlockDecorationList { return list.decorations.compactMap(inset) }
    if let single = deco as? BlockDecoration { return inset(single).map { [$0] } ?? [] }
    return []
}

/// A blockquote `>` marker hides by going clear-colored at *normal* font size
/// (not the near-zero `hiddenFont` other delimiters use) — its glyph advance
/// is what makes a wrapping line's continuation land under the hanging
/// indent. `isHidden` (TestHelpers) checks for the `hiddenFont` case and so
/// doesn't apply here; this checks only the color.
private func isMarkerHidden(at offset: Int, in s: NSAttributedString) -> Bool {
    guard offset < s.length else { return false }
    return (s.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor) == .clear
}

@Suite("Blockquote rendering — nesting")
@MainActor
struct BlockquoteNestingTests {

    @Test("A single-level quote renders one bar, marker hidden")
    func singleLevel() {
        let editor = makeEditor()
        let s = editor.styleBlock("> hello")
        #expect(isMarkerHidden(at: 0, in: s))
        let insets = barInsets(s.attribute(.blockDecoration, at: 2, effectiveRange: nil))
        #expect(insets == [0])
    }

    @Test("A nested quote (> >) hides both markers and stacks two bars, outer leftmost")
    func nestedOnce() {
        let editor = makeEditor()
        let md = "> outer\n> > inner"
        let s = editor.styleBlock(md)
        let ns = md as NSString
        // Outer marker (position 0) hidden.
        #expect(isMarkerHidden(at: 0, in: s))
        // Inner marker (the second '>' on line 2) hidden too.
        let innerMarker = ns.range(of: "> inner").location
        #expect(isMarkerHidden(at: innerMarker, in: s))
        // Inner text carries two stacked bars: outer bumped out, inner at 0.
        let innerTextLoc = ns.range(of: "inner").location
        let insets = barInsets(decorationList(at: innerTextLoc, in: s))
        #expect(insets.count == 2)
        #expect(insets.contains(0))
        #expect(insets.max() ?? 0 > 0)
    }

    @Test("Triple nesting stacks three bars in order; dropping back to level 1 leaves one")
    func tripleNestingAndDropBack() {
        let editor = makeEditor()
        let md = "> level one\n> > level two\n> > > level three\n> back to one"
        let s = editor.styleBlock(md)
        let ns = md as NSString

        let l3Loc = ns.range(of: "level three").location
        let l3Insets = barInsets(decorationList(at: l3Loc, in: s))
        #expect(l3Insets.count == 3)
        // Sorted ascending: deepest (0) ... outermost (largest).
        let sorted = l3Insets.sorted()
        #expect(sorted[0] == 0)
        #expect(sorted[1] > sorted[0])
        #expect(sorted[2] > sorted[1])

        // "back to one" is only nested one level deep — a single bar at inset 0.
        let backLoc = ns.range(of: "back to one").location
        let backDeco = s.attribute(.blockDecoration, at: backLoc, effectiveRange: nil)
        #expect(barInsets(backDeco) == [0])
        // And its marker (the lone '>' on that line) is hidden, not literal.
        let backMarker = ns.range(of: "> back to one").location
        #expect(isMarkerHidden(at: backMarker, in: s))
    }

    @Test("A callout nested inside a plain quote stays literal (unchanged from before)")
    func calloutInsideQuoteStaysLiteral() {
        let editor = makeEditor()
        let s = editor.styleBlock("> intro\n> > [!note] still literal")
        // No fragment overlay (header icon+title image) anywhere — the nested
        // callout never renders as a callout.
        var hasOverlay = false
        s.enumerateAttribute(.fragmentOverlay, in: NSRange(location: 0, length: s.length),
                             options: []) { v, _, stop in if v != nil { hasOverlay = true; stop.pointee = true } }
        #expect(!hasOverlay)
        // The raw "[!note]" text is visible, not hidden.
        let ns = ("> intro\n> > [!note] still literal") as NSString
        let bracket = ns.range(of: "[!note]").location
        #expect(!isMarkerHidden(at: bracket, in: s))
    }

    @Test("Active (cursor inside) nested quote shows raw dimmed markers, not hidden")
    func activeNestedQuoteShowsRaw() {
        let editor = makeEditor()
        let md = "> outer\n> > inner"
        let s = editor.styleBlock(md, cursorPosition: (md as NSString).range(of: "inner").location)
        // Cursor is inside — markers dimmed (visible), not hidden.
        #expect(!isMarkerHidden(at: 0, in: s))
    }
}
