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

    @Test("Custom title renders as live bold, tinted text (so it can wrap)")
    @MainActor func customTitleVisible() {
        let editor = makeEditor()
        let styled = editor.styleBlock("> [!note] My Title\n> body")
        let s = styled.string as NSString
        let r = s.range(of: "My Title")
        #expect(r.location != NSNotFound)
        // No longer baked into a fixed-width image — it's real text that wraps.
        #expect(!isHidden(at: r.location, in: styled))
        let f = styled.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont
        #expect(f?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        let color = styled.attribute(.foregroundColor, at: r.location, effectiveRange: nil) as? NSColor
        #expect(color != nil && color != .clear && color != .textColor)
        // The `[!note]` marker before the title is still hidden.
        let marker = s.range(of: "[!note]")
        #expect(isHidden(at: marker.location, in: styled))
    }

    @Test("A long custom title wraps to multiple lines instead of clipping")
    @MainActor func longCustomTitleWraps() {
        let editor = makeEditor()   // ~500pt container
        let longTitle = "Does the title of callouts wrap around when the window "
            + "is too small to fit it on a single line of text"
        editor.loadContent("> [!question] \(longTitle)\n> body\n")
        ensureFullLayout(editor)

        let off = (editor.rawSource as NSString).range(of: "Does the title").location
        #expect(off != NSNotFound)
        guard let tlm = editor.textLayoutManager,
              let loc = tlm.location(tlm.documentRange.location, offsetBy: off),
              let frag = tlm.textLayoutFragment(for: loc) else {
            Issue.record("no header fragment"); return
        }
        // Real wrapping text → the header paragraph lays out on 2+ line fragments.
        // (The old fixed-width title image was a single non-wrapping line.)
        #expect(frag.textLineFragments.count >= 2,
                "expected the title to wrap, got \(frag.textLineFragments.count) line(s)")
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
