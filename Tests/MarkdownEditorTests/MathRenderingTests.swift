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
