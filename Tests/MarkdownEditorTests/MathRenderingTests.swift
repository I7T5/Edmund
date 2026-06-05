import Testing
import AppKit
import SwiftMath
@testable import MarkdownEditorCore

@Suite("Math — SwiftMath smoke test")
struct MathSmokeTests {

    @Test("SwiftMath renders a valid expression to a non-nil image")
    func rendersValidLatex() {
        let math = MTMathImage(latex: "x^2 + 1", fontSize: 16,
                               textColor: .labelColor, labelMode: .text)
        let (error, image) = math.asImage()
        #expect(error == nil)
        #expect(image != nil)
        if let image { #expect(image.size.width > 0 && image.size.height > 0) }
    }

    @Test("SwiftMath returns an error for invalid LaTeX")
    func rejectsInvalidLatex() {
        let math = MTMathImage(latex: "\\frac{", fontSize: 16,
                               textColor: .labelColor, labelMode: .text)
        let (error, _) = math.asImage()
        #expect(error != nil)
    }
}

@Suite("Math — Inline rendering")
struct InlineMathRenderingTests {

    @Test("Inactive $x^2$ shows an attachment and hides the source")
    @MainActor func inactiveRendersAttachment() {
        let editor = makeEditor()
        let styled = editor.styleBlock("$x^2$")           // no cursor → render
        // Attachment replaces the opening `$`.
        let attachment = styled.attribute(.attachment, at: 0, effectiveRange: nil)
        #expect(attachment is NSTextAttachment)
        // LaTeX source + closing `$` are hidden.
        #expect(isHidden(at: 1, in: styled))
        #expect(isHidden(at: 4, in: styled))
    }

    @Test("Active $x^2$ (cursor inside) shows raw, no attachment")
    @MainActor func activeShowsRaw() {
        let editor = makeEditor()
        let styled = editor.styleBlock("$x^2$", cursorPosition: 2)
        #expect(styled.attribute(.attachment, at: 0, effectiveRange: nil) == nil)
        #expect(!isHidden(at: 1, in: styled))             // source visible
    }

    @Test("Invalid LaTeX shows the raw source tinted, no attachment")
    @MainActor func invalidLatexFallsBack() {
        let editor = makeEditor()
        let styled = editor.styleBlock("$\\frac{$")
        #expect(styled.attribute(.attachment, at: 0, effectiveRange: nil) == nil)
        #expect(!isHidden(at: 1, in: styled))             // raw source shown
        let color = styled.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == NSColor.systemRed)
    }
}

@Suite("Math — Display rendering")
struct DisplayMathRenderingTests {

    @Test("Inactive $$…$$ shows an attachment and hides the source")
    @MainActor func inactiveRendersAttachment() {
        let editor = makeEditor()
        let styled = editor.styleBlock("$$x+y$$")
        // Attachment replaces the first `$`.
        #expect(styled.attribute(.attachment, at: 0, effectiveRange: nil) is NSTextAttachment)
        // The second `$` of the opening delimiter is hidden too.
        #expect(isHidden(at: 1, in: styled))
        #expect(isHidden(at: 2, in: styled))             // content
    }

    @Test("Display math is centered")
    @MainActor func displayIsCentered() {
        let editor = makeEditor()
        let styled = editor.styleBlock("$$x+y$$")
        let ps = styled.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(ps?.alignment == .center)
    }

    @Test("Active $$…$$ (cursor inside) shows raw, no attachment")
    @MainActor func activeShowsRaw() {
        let editor = makeEditor()
        let styled = editor.styleBlock("$$x+y$$", cursorPosition: 3)
        #expect(styled.attribute(.attachment, at: 0, effectiveRange: nil) == nil)
        #expect(!isHidden(at: 2, in: styled))             // source visible
    }
}
