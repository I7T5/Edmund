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
        let attachment = styled.attribute(.fragmentOverlay, at: 0, effectiveRange: nil)
        #expect(attachment is FragmentOverlay)
        // LaTeX source + closing `$` are hidden.
        #expect(isHidden(at: 1, in: styled))
        #expect(isHidden(at: 4, in: styled))
    }

    @Test("Active $x^2$ (cursor inside) shows raw, no attachment")
    @MainActor func activeShowsRaw() {
        let editor = makeEditor()
        let styled = editor.styleBlock("$x^2$", cursorPosition: 2)
        #expect(styled.attribute(.fragmentOverlay, at: 0, effectiveRange: nil) == nil)
        #expect(!isHidden(at: 1, in: styled))             // source visible
    }

    @Test("Invalid LaTeX shows the raw source tinted, no attachment")
    @MainActor func invalidLatexFallsBack() {
        let editor = makeEditor()
        let styled = editor.styleBlock("$\\frac{$")
        #expect(styled.attribute(.fragmentOverlay, at: 0, effectiveRange: nil) == nil)
        #expect(!isHidden(at: 1, in: styled))             // raw source shown
        let color = styled.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == NSColor.systemRed)
    }
}

@Suite("Math — Source coloring")
struct MathSourceColoringTests {

    @MainActor private func color(_ s: NSAttributedString, at i: Int) -> String? {
        (s.attribute(.foregroundColor, at: i, effectiveRange: nil) as? NSColor)?.hexString
    }

    @Test("Active math colors _, ^ as operators and digits as numbers")
    @MainActor func operatorsAndNumbers() {
        let editor = makeEditor()
        let styled = editor.styleBlock("$x_1^2$", cursorPosition: 3)   // active
        let op = editor.theme.mathOperatorColor.hexString
        let num = editor.theme.mathNumberColor.hexString
        // $0 x1 _2 13 ^4 25 $6
        #expect(color(styled, at: 2) == op)    // _
        #expect(color(styled, at: 3) == num)   // 1
        #expect(color(styled, at: 4) == op)    // ^
        #expect(color(styled, at: 5) == num)   // 2
        #expect(color(styled, at: 1) != op)    // x is neither
        #expect(color(styled, at: 1) != num)
    }

    @Test("Active math colors a backslash command as an operator")
    @MainActor func backslashCommand() {
        let editor = makeEditor()
        let styled = editor.styleBlock("$\\alpha+1$", cursorPosition: 2)
        let op = editor.theme.mathOperatorColor.hexString
        let num = editor.theme.mathNumberColor.hexString
        // $0 \1 a2 l3 p4 h5 a6 +7 18 $9
        #expect(color(styled, at: 1) == op)    // backslash
        #expect(color(styled, at: 4) == op)    // inside \alpha
        #expect(color(styled, at: 8) == num)   // 1
    }
}

@Suite("Math — Display rendering")
struct DisplayMathRenderingTests {

    @Test("Inactive $$…$$ shows an attachment and hides the source")
    @MainActor func inactiveRendersAttachment() {
        let editor = makeEditor()
        let styled = editor.styleBlock("$$x+y$$")
        // Attachment replaces the first `$`.
        #expect(styled.attribute(.fragmentOverlay, at: 0, effectiveRange: nil) is FragmentOverlay)
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
        #expect(styled.attribute(.fragmentOverlay, at: 0, effectiveRange: nil) == nil)
        #expect(!isHidden(at: 2, in: styled))             // source visible
    }
}

@Suite("Math — Fit to width")
struct MathFitWidthTests {

    // The test editor's container is 500 wide; usable width ≈ 500 − 2·5 padding.
    private let cap: CGFloat = 490

    @Test("A very wide equation is scaled down to the text width")
    @MainActor func wideScaled() {
        let editor = makeEditor()
        // Pin the font size so the equation is reliably wider than the cap
        // regardless of the default theme: at 24pt its natural width (~780)
        // comfortably exceeds the 490 cap, so the scale-down branch must run.
        var theme = editor.theme
        theme.fontSize = 24
        editor.theme = theme

        // Pin the container width so the usable width is exactly 500 − 2·5 = 490.
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.size = NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)

        let wide = "$$a_{10}x^{10}+a_9x^9+a_8x^8+a_7x^7+a_6x^6+a_5x^5+a_4x^4+a_3x^3+a_2x^2+a_1x+a_0$$"
        let styled = editor.styleBlock(wide)
        let att = styled.attribute(.fragmentOverlay, at: 0, effectiveRange: nil) as? FragmentOverlay
        #expect(att != nil)
        // The natural width exceeds the usable width, so it scales down to
        // exactly the cap (500 − 2·5 line-fragment padding).
        #expect(abs((att?.bounds.width ?? 0) - cap) < 1)
    }

    @Test("A normal-width equation is not scaled")
    @MainActor func normalNotScaled() {
        let editor = makeEditor()
        let styled = editor.styleBlock("$$x+y$$")
        let att = styled.attribute(.fragmentOverlay, at: 0, effectiveRange: nil) as? FragmentOverlay
        #expect(att != nil)
        let w = att?.bounds.width ?? 0
        #expect(w > 0 && w < 200)        // comfortably under the cap
    }
}
