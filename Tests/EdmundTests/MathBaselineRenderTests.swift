import Testing
import AppKit
@testable import EdmundCore

// Inline math has to sit on the text baseline to the device pixel, for every
// engine. Measured on the real draw path: an `EditorTextView` laid out
// offscreen and rendered with `cacheDisplay`, then the ink of a body-text `H`
// compared with the ink of `$\mathrm{H}$` beside it. Both H's are flat-bottomed
// on the baseline and flat-topped at cap height in every font involved (SF,
// Latin Modern, KaTeX Main), so their stems' bottom edges must agree.
//
// Edges are read with sub-pixel precision from the stem column's coverage
// profile (a stem's anti-aliased bottom row carries the fractional part), so
// a half-pixel error shows as 0.5, not as 0 or 1.
//
// RaTeX runs only with RATEX_DIR set to an installed payload directory (e.g.
// ~/Library/Application Support/Edmund/Math/ratex-<v>); SwiftMath always runs.

@Suite("Math baseline — rendered", .serialized)
@MainActor
struct MathBaselineRenderTests {

    private static let doc = """
        caret

        H $\\mathrm{H}$ H

        ## H $\\mathrm{H}$ H

        $y$

        H $\\mathrm{H}$ H

        $\\int$

        H $\\mathrm{H}$ H

        $j_1$

        ## H $\\mathrm{H}$ H

        """
    /// Lines holding text-H, math-H, text-H. The one-glyph equations between
    /// them have fractional descents, which reserve fractional line heights and
    /// so put each measured line on a different sub-pixel offset.
    private static let measuredLines = 5

    /// One glyph's ink: its column span and the sub-pixel top/bottom edges of
    /// its left stem, in device pixels from the top of the view.
    struct Ink { let minX: Int; let maxX: Int; let top: Double; let bottom: Double }

    /// Renders at `scale` explicitly. `cacheDisplay`'s default rep follows the
    /// screen, and a headless CI runner hands back a 1x rep while `mathOverlay`
    /// (no window, no main screen) snaps for 2x. A window never mixes the two,
    /// so neither may the test.
    private func render(_ editor: EditorTextView, scale: CGFloat) -> NSBitmapImageRep {
        let bounds = editor.bounds
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = bounds.size
        editor.cacheDisplay(in: bounds, to: rep)
        if let dir = ProcessInfo.processInfo.environment["MATH_BASELINE_PNG_DIR"] {
            let name = MathRendering.shared.active.id.replacingOccurrences(of: "@", with: "-")
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("baseline-\(name).png"))
        }
        return rep
    }

    /// Glyph ink per text line: rows are banded into lines by blank rows, and
    /// each line into glyphs by blank columns.
    private func glyphs(in rep: NSBitmapImageRep) -> [[Ink]] {
        let w = rep.pixelsWide, h = rep.pixelsHigh
        var dark = [Double](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let b = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.brightnessComponent ?? 1
                dark[y * w + x] = 1 - b
            }
        }
        let ink = 0.04
        func rowHasInk(_ y: Int) -> Bool { (0..<w).contains { dark[y * w + $0] > ink } }

        var lines: [[Ink]] = []
        var y = 0
        while y < h {
            guard rowHasInk(y) else { y += 1; continue }
            let y0 = y
            while y < h, rowHasInk(y) { y += 1 }
            let y1 = y   // band [y0, y1)
            func colHasInk(_ x: Int) -> Bool { (y0..<y1).contains { dark[$0 * w + x] > ink } }
            var line: [Ink] = []
            var x = 0
            while x < w {
                guard colHasInk(x) else { x += 1; continue }
                let x0 = x
                while x < w, colHasInk(x) { x += 1 }
                // Left stem: the darkest column within the glyph's left third.
                let stemRange = x0..<max(x0 + 1, x0 + (x - x0) / 3)
                func colInk(_ c: Int) -> Double {
                    var s = 0.0
                    for r in y0..<y1 { s += dark[r * w + c] }
                    return s
                }
                let stem = stemRange.max { colInk($0) < colInk($1) }!
                let profile = (y0..<y1).map { dark[$0 * w + stem] }
                let full = profile.max() ?? 1
                let mid = profile.count / 2
                // Sub-pixel edges: full-coverage rows count 1, the AA row its fraction.
                let bottom = Double(y0 + mid) + profile[mid...].reduce(0) { $0 + $1 / full }
                let top = Double(y0 + mid) - profile[..<mid].reduce(0) { $0 + $1 / full }
                line.append(Ink(minX: x0, maxX: x - 1, top: top, bottom: bottom))
            }
            lines.append(line)
        }
        return lines
    }

    /// The scale `mathOverlay` snaps to for a window-less editor.
    private var overlayScale: CGFloat { NSScreen.main?.backingScaleFactor ?? 2 }

    private func measure(scale: CGFloat) -> (lines: [[Ink]], textFont: NSFont, scale: CGFloat) {
        let editor = makeEditor()
        editor.frame.size.height = 700
        editor.appearance = NSAppearance(named: .aqua)
        editor.updateContentInset()
        editor.loadContent(Self.doc)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        ensureFullLayout(editor)
        layOutViewport(editor)
        let rep = render(editor, scale: scale)
        let at = (editor.string as NSString).range(of: "H $").location
        let font = editor.textStorage!.attribute(.font, at: at, effectiveRange: nil) as! NSFont
        // Drop the one-glyph lines; keep the lines holding text-H, math-H, text-H.
        return (glyphs(in: rep).filter { $0.count == 3 }, font, CGFloat(rep.pixelsWide) / editor.bounds.width)
    }

    /// Advance and ink extent of `H` in `font`, plus the advance of a space.
    private func hMetrics(_ font: NSFont) -> (advance: CGFloat, ink: CGRect, space: CGFloat) {
        var chars: [UniChar] = [72, 32]
        var glyphs: [CGGlyph] = [0, 0]
        CTFontGetGlyphsForCharacters(font, &chars, &glyphs, 2)
        var adv = [CGSize](repeating: .zero, count: 2)
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &adv, 2)
        return (adv[0].width, CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyphs, nil, 1), adv[1].width)
    }

    private func check(_ m: (lines: [[Ink]], textFont: NSFont, scale: CGFloat), engine: String) {
        #expect(m.lines.count == Self.measuredLines, "\(engine): measured \(m.lines.count) lines")
        let h = hMetrics(m.textFont)
        for (i, g) in m.lines.enumerated() {
            let (text, math, after) = (g[0], g[1], g[2])
            let dBottom = math.bottom - text.bottom
            let dTop = math.top - text.top
            // Blank device pixels between the math image's edges and the math
            // ink: the measured gap minus the text-side part (the H's side
            // bearing plus the space). Only the body lines use the body font.
            let heading = text.bottom - text.top > (h.ink.height + 2) * m.scale
            let leftInset = Double(math.minX - text.maxX - 1) - (h.advance + h.space - h.ink.maxX) * m.scale
            let rightInset = Double(after.minX - math.maxX - 1) - (h.space + h.ink.minX) * m.scale
            print("[\(engine)@\(m.scale)x] line \(i)\(heading ? " (heading)" : ""): baseline Δ \(dBottom)px, top Δ \(dTop)px"
                  + (heading ? "" : "; math side insets \(leftInset)px / \(rightInset)px"))
            #expect(abs(dBottom) < 0.25, "\(engine) line \(i): math baseline off by \(dBottom) device px")
            if !heading {
                // An H's own side bearing is ~1px; a 2pt pad each side made it ~5.
                #expect(leftInset < 2.5 && rightInset < 2.5,
                        "\(engine) line \(i): \(leftInset)px / \(rightInset)px blank beside the math")
            }
        }
    }

    @Test("SwiftMath sits on the text baseline")
    func swiftMath() {
        let saved = MathRendering.shared.alternate
        MathRendering.shared.alternate = nil
        defer { MathRendering.shared.alternate = saved }
        check(measure(scale: overlayScale), engine: "swiftmath")
    }

    @Test("RaTeX sits on the text baseline, with no padding beside it")
    func ratex() {
        guard let dir = ProcessInfo.processInfo.environment["RATEX_DIR"] else { return }
        let host = WasmMathHost()
        host.load(dir: URL(fileURLWithPath: dir))
        #expect(host.isLoaded)
        let saved = MathRendering.shared.alternate
        MathRendering.shared.alternate = RaTeXRenderer(host: host)
        defer { MathRendering.shared.alternate = saved }
        check(measure(scale: overlayScale), engine: "ratex")
    }
}
