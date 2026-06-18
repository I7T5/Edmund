import Testing
import AppKit
@testable import EdmundCore

@Suite("Callout — rendering")
struct CalloutRenderingTests {

    // "> [!note]…"  indices: 0'>' 1' ' 2'[' 3'!' 4'n' 5'o' 6't' 7'e' 8']'

    private func boxDecoration(_ deco: BlockDecoration?)
        -> (background: NSColor, borderColor: NSColor?, edges: CalloutStyle.Edges, width: CGFloat)? {
        guard let deco, case .box(let bg, let border, let edges, let width, _) = deco.kind
        else { return nil }
        return (bg, border, edges, width)
    }

    @Test("Rendered callout: header replaced by an image, source hidden, tinted bg, no border")
    @MainActor func rendered() {
        let editor = makeEditor()
        let styled = editor.styleBlock("> [!note]\n> body")

        // The header image sits on "[".
        let att = styled.attribute(.fragmentOverlay, at: 2, effectiveRange: nil) as? FragmentOverlay
        #expect(att != nil)
        #expect(att?.image != nil)
        // The raw "[!note]" header is hidden (near-zero font + clear) — its title
        // is drawn inside the image instead.
        for i in 3...8 { #expect(isHidden(at: i, in: styled)) }
        // A tinted background marks the callout; no border by default.
        let box = boxDecoration(blockDecoration(at: 0, in: styled))
        #expect(box != nil)
        #expect(box?.edges.isEmpty == true)
    }

    @Test("Last line carries the box bottom padding; earlier lines don't")
    @MainActor func lastLineBottomPad() {
        let editor = makeEditor()
        let styled = editor.styleBlock("> [!note]\n> first\n> last")
        func bottomPad(at i: Int) -> CGFloat? {
            guard case .box(_, _, _, _, let bp)? = blockDecoration(at: i, in: styled)?.kind
            else { return nil }
            return bp
        }
        let ns = styled.string as NSString
        let lastStart = ns.range(of: "\n", options: .backwards).upperBound
        // TextKit 2 omits trailing paragraphSpacing from the fragment frame, so
        // the bottom breathing room is drawn by extending the last line's box.
        #expect((bottomPad(at: 0) ?? -1) == 0)             // header line
        #expect((bottomPad(at: lastStart) ?? 0) > 0)        // last line
    }

    @Test("Unknown type stays a plain block quote")
    @MainActor func unknownPlain() {
        let editor = makeEditor()
        let styled = editor.styleBlock("> [!bogus]\n> body")
        #expect(styled.attribute(.fragmentOverlay, at: 2, effectiveRange: nil) == nil)
        #expect(!isHidden(at: 3, in: styled))
    }

    @Test("Active callout shows the raw marker, no image")
    @MainActor func activeRaw() {
        let editor = makeEditor()
        let styled = editor.styleBlock("> [!note]\n> body", cursorPosition: 4)
        #expect(styled.attribute(.fragmentOverlay, at: 2, effectiveRange: nil) == nil)
        #expect(!isHidden(at: 2, in: styled))   // "[" visible (dimmed), editable
    }

    @Test("Callout's left inset does not exceed a plain block quote's")
    @MainActor func leftInsetNotLargerThanBlockquote() {
        let editor = makeEditor()
        // The text inset now lives on the paragraph style (the decoration is
        // drawn at the fragment edge behind it).
        func leftInset(_ s: String) -> CGFloat? {
            let st = editor.styleBlock(s)
            let ps = st.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            return ps?.headIndent
        }
        let callout = leftInset("> [!note]\n> x")
        let quote = leftInset("> x")
        #expect((callout ?? -1) > 0 && (quote ?? -1) > 0)
        #expect((callout ?? .infinity) <= (quote ?? 0) + 0.01)
    }

    @Test("The tinted background covers the callout's body lines too")
    @MainActor func backgroundCoversBody() {
        let editor = makeEditor()
        let styled = editor.styleBlock("> [!note]\n> body line")
        let bodyIdx = (styled.string as NSString).range(of: "body").location
        #expect(bodyIdx != NSNotFound)
        #expect(boxDecoration(blockDecoration(at: bodyIdx, in: styled)) != nil)
    }

    @Test("Custom title text is hidden (drawn in the header image)")
    @MainActor func customTitleHidden() {
        let editor = makeEditor()
        let styled = editor.styleBlock("> [!note] My Title\n> body")
        // "My Title" (after the marker) is part of the hidden header.
        let r = (styled.string as NSString).range(of: "My Title")
        #expect(r.location != NSNotFound)
        #expect(isHidden(at: r.location, in: styled))
    }

    @Test("Style overrides change the bar color and border edges")
    @MainActor func overridesApplied() {
        let editor = makeEditor()
        editor.calloutStyleOverrides = [
            "note": CalloutStyle(symbolName: "star.fill", colorHex: "#112233",
                                 borderEdges: .all, borderWidth: 2)
        ]
        let styled = editor.styleBlock("> [!note]\n> body")
        let box = boxDecoration(blockDecoration(at: 0, in: styled))
        #expect(box?.borderColor?.hexString == NSColor(hex: "#112233")?.hexString)
        #expect(box?.edges == .all)
        #expect(box?.width == 2)
    }
}
