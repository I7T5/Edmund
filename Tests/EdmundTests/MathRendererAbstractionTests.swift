import Testing
import AppKit
@testable import EdmundCore

@Suite("MathRenderer — abstraction")
struct MathRendererAbstractionTests {

    @MainActor
    private final class FakeRenderer: MathRenderer {
        let id: String
        var isReady: Bool
        var lastLatex: String?
        init(id: String, isReady: Bool) { self.id = id; self.isReady = isReady }
        func render(latex: String, displayMode: Bool,
                   pointSize: CGFloat, color: NSColor) -> RenderedMath? {
            lastLatex = latex
            guard latex != "unsupported" else { return nil }
            return RenderedMath(image: NSImage(size: NSSize(width: 42, height: 42)),
                                ascent: 30, descent: 12)
        }
    }

    @Test("SwiftMathRenderer renders valid LaTeX with ascent+descent summing to image height")
    @MainActor func swiftMathRendersValidLatex() {
        let r = SwiftMathRenderer()
        let out = r.render(latex: "x^2", displayMode: false, pointSize: 16, color: NSColor(red: 0, green: 0, blue: 0, alpha: 1))
        #expect(out != nil)
        if let out { #expect(abs((out.ascent + out.descent) - out.image.size.height) < 0.01) }
    }

    @Test("SwiftMathRenderer returns nil for invalid LaTeX")
    @MainActor func swiftMathRejectsInvalidLatex() {
        let r = SwiftMathRenderer()
        #expect(r.render(latex: "\\frac{", displayMode: false, pointSize: 16, color: NSColor(red: 0, green: 0, blue: 0, alpha: 1)) == nil)
    }

    @Test("Coordinator defaults to SwiftMath when no alternate is set")
    @MainActor func defaultsToSwiftMath() {
        let coord = MathRendering.shared
        coord.alternate = nil
        #expect(coord.active === coord.swiftMath)
    }

    @Test("Coordinator prefers a ready alternate engine")
    @MainActor func prefersReadyAlternate() {
        let coord = MathRendering.shared
        let fake = FakeRenderer(id: "fake", isReady: true)
        coord.alternate = fake
        defer { coord.alternate = nil }
        #expect(coord.active === fake)
    }

    @Test("Coordinator falls back to SwiftMath when the alternate isn't ready")
    @MainActor func fallsBackWhenNotReady() {
        let coord = MathRendering.shared
        let fake = FakeRenderer(id: "fake", isReady: false)
        coord.alternate = fake
        defer { coord.alternate = nil }
        #expect(coord.active === coord.swiftMath)
    }

    @Test("Coordinator falls back to SwiftMath per-equation when the alternate can't render it")
    @MainActor func perEquationFallback() {
        let coord = MathRendering.shared
        let fake = FakeRenderer(id: "fake", isReady: true)
        coord.alternate = fake
        defer { coord.alternate = nil }
        let result = coord.render(latex: "unsupported", displayMode: false, pointSize: 16, color: NSColor(red: 0, green: 0, blue: 0, alpha: 1))
        #expect(result != nil)             // SwiftMath rendered it anyway
        #expect(fake.lastLatex == "unsupported")   // the fake was tried first
    }

    @Test("Switching engines and notifying re-renders an already-styled math block")
    @MainActor func engineChangeRestylesExistingMath() {
        let editor = makeEditor()
        // The caret defaults to offset 0 after load; text before the equation
        // keeps that offset outside the math token so the recompose renders it
        // (cursor-inside-token shows raw source instead, skipping the overlay).
        editor.loadContent("hi $x^2$ there")
        ensureFullLayout(editor)
        drainAllStyling(editor)

        let fake = FakeRenderer(id: "fake", isReady: true)
        MathRendering.shared.alternate = fake
        defer { MathRendering.shared.alternate = nil }
        MathRendering.shared.engineDidChange()

        #expect(fake.lastLatex == "x^2")
    }
}
