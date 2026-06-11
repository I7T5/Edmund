import Testing
import AppKit
@testable import MarkdownEditorCore

@Suite("Callout — rendering")
struct CalloutRenderingTests {

    private let leftEdge = NSRectEdge(rawValue: 0)!

    // "> [!note]…"  indices: 0'>' 1' ' 2'[' 3'!' 4'n' 5'o' 6't' 7'e' 8']'

    @Test("Rendered callout: header replaced by an image, source hidden, tinted bg, no border")
    @MainActor func rendered() {
        let editor = makeEditor()
        let styled = editor.styleBlock("> [!note]\n> body")

        // The header image sits on "[".
        let att = styled.attribute(.attachment, at: 2, effectiveRange: nil) as? NSTextAttachment
        #expect(att != nil)
        #expect(att?.image != nil)
        // The raw "[!note]" header is hidden (near-zero font + clear) — its title
        // is drawn inside the image instead.
        for i in 3...8 { #expect(isHidden(at: i, in: styled)) }
        // A tinted background marks the callout; no border by default.
        let block = styled.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
            .flatMap { ($0 as? NSParagraphStyle)?.textBlocks.first }
        #expect(block?.backgroundColor != nil)
        #expect(block?.borderColor(for: leftEdge) == nil)
    }

    @Test("Unknown type stays a plain block quote")
    @MainActor func unknownPlain() {
        let editor = makeEditor()
        let styled = editor.styleBlock("> [!bogus]\n> body")
        #expect(styled.attribute(.attachment, at: 2, effectiveRange: nil) == nil)
        #expect(!isHidden(at: 3, in: styled))
    }

    @Test("Active callout shows the raw marker, no image")
    @MainActor func activeRaw() {
        let editor = makeEditor()
        let styled = editor.styleBlock("> [!note]\n> body", cursorPosition: 4)
        #expect(styled.attribute(.attachment, at: 2, effectiveRange: nil) == nil)
        #expect(!isHidden(at: 2, in: styled))   // "[" visible (dimmed), editable
    }

    @Test("Callout's left inset does not exceed a plain block quote's")
    @MainActor func leftInsetNotLargerThanBlockquote() {
        let editor = makeEditor()
        let left = leftEdge
        func leftInset(_ s: String) -> CGFloat {
            let st = editor.styleBlock(s)
            guard let b = (st.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
                as? NSParagraphStyle)?.textBlocks.first else { return -1 }
            return b.width(for: .border, edge: left) + b.width(for: .padding, edge: left)
        }
        let callout = leftInset("> [!note]\n> x")
        let quote = leftInset("> x")
        #expect(callout > 0 && quote > 0)
        #expect(callout <= quote + 0.01)
    }

    @Test("The tinted background covers the callout's body lines too")
    @MainActor func backgroundCoversBody() {
        let editor = makeEditor()
        let styled = editor.styleBlock("> [!note]\n> body line")
        let bodyIdx = (styled.string as NSString).range(of: "body").location
        #expect(bodyIdx != NSNotFound)
        let ps = styled.attribute(.paragraphStyle, at: bodyIdx, effectiveRange: nil) as? NSParagraphStyle
        #expect(ps?.textBlocks.first?.backgroundColor != nil)
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
        let block = styled.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
            .flatMap { ($0 as? NSParagraphStyle)?.textBlocks.first }
        #expect(block?.borderColor(for: leftEdge)?.hexString == NSColor(hex: "#112233")?.hexString)
        // All four edges now have a border.
        let top = NSRectEdge(rawValue: 1)!, right = NSRectEdge(rawValue: 2)!, bottom = NSRectEdge(rawValue: 3)!
        #expect(block?.borderColor(for: top) != nil)
        #expect(block?.borderColor(for: right) != nil)
        #expect(block?.borderColor(for: bottom) != nil)
    }
}
