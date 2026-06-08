import Testing
import AppKit
@testable import MarkdownEditorCore

@Suite("Callout — rendering")
struct CalloutRenderingTests {

    private let noteHex = Callout.defaultStyles["note"]!.colorHex
    private let leftEdge = NSRectEdge(rawValue: 0)!

    // "> [!note]…"  indices: 0'>' 1' ' 2'[' 3'!' 4'n' 5'o' 6't' 7'e' 8']'

    @Test("Rendered callout: icon, hidden brackets, colored bold label, colored bar")
    @MainActor func rendered() {
        let editor = makeEditor()
        let styled = editor.styleBlock("> [!note]\n> body")

        // Icon attachment replaces "[".
        #expect(styled.attribute(.attachment, at: 2, effectiveRange: nil) is NSTextAttachment)
        // "!" and "]" are hidden (near-zero font + clear).
        #expect(isHidden(at: 3, in: styled))
        #expect(isHidden(at: 8, in: styled))
        // The type label "note" is colored and bold.
        let fg = styled.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor
        #expect(fg?.hexString == NSColor(hex: noteHex)?.hexString)
        let f = styled.attribute(.font, at: 4, effectiveRange: nil) as? NSFont
        #expect(f.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true)
        // The left bar is the callout color.
        let ps = styled.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let block = ps?.textBlocks.first
        #expect(block?.borderColor(for: leftEdge)?.hexString == NSColor(hex: noteHex)?.hexString)
    }

    @Test("Unknown type stays a plain block quote")
    @MainActor func unknownPlain() {
        let editor = makeEditor()
        let styled = editor.styleBlock("> [!bogus]\n> body")
        // No icon; the literal "[!bogus]" stays visible.
        #expect(styled.attribute(.attachment, at: 2, effectiveRange: nil) == nil)
        #expect(!isHidden(at: 3, in: styled))
    }

    @Test("Active callout shows the raw marker, no icon")
    @MainActor func activeRaw() {
        let editor = makeEditor()
        let styled = editor.styleBlock("> [!note]\n> body", cursorPosition: 4)
        #expect(styled.attribute(.attachment, at: 2, effectiveRange: nil) == nil)
        #expect(!isHidden(at: 2, in: styled))   // "[" visible (dimmed), editable
    }

    @Test("The colored bar covers the callout's body lines too")
    @MainActor func barCoversBody() {
        let editor = makeEditor()
        let styled = editor.styleBlock("> [!note]\n> body line")
        // Pick a character on the body line and confirm it carries the same
        // colored bar as the header line.
        let bodyIdx = (styled.string as NSString).range(of: "body").location
        #expect(bodyIdx != NSNotFound)
        let ps = styled.attribute(.paragraphStyle, at: bodyIdx, effectiveRange: nil) as? NSParagraphStyle
        #expect(ps?.textBlocks.first?.borderColor(for: leftEdge)?.hexString
                == NSColor(hex: noteHex)?.hexString)
    }

    @Test("Case-insensitive type renders as a callout")
    @MainActor func caseInsensitiveRenders() {
        let editor = makeEditor()
        let styled = editor.styleBlock("> [!TIP]\n> body")
        #expect(styled.attribute(.attachment, at: 2, effectiveRange: nil) is NSTextAttachment)
        let tipHex = Callout.defaultStyles["tip"]!.colorHex
        let fg = styled.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor
        #expect(fg?.hexString == NSColor(hex: tipHex)?.hexString)
    }
}
