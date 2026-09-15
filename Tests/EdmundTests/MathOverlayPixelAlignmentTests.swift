import Testing
import AppKit
import CoreText
@testable import EdmundCore

// A math bitmap is rasterized at the backing scale, so it only stays crisp if
// its destination rect covers a whole number of device pixels at a whole-pixel
// origin. Edit mode used to satisfy neither: it drew at the NSImage's point size
// (rounded independently of the bitmap's pixel count) at a baseline-derived
// fractional origin, so Core Graphics resampled the blit and the same ink spread
// over ~35% more device pixels — equations read slightly bolder and softer than
// the identical image in Read mode, which pins its `<img>` to the PNG's exact
// pixel count (`DocumentHTML.fillMath`).
//
// The two production halves are `EditorTextView.mathOverlay` (snaps the overlay
// size onto the device grid) and `deviceAligned` in EditorTextView+TextKit2
// (snaps the draw origin). Either one alone still resamples, so both are
// measured here.

@Suite("Math overlay pixel alignment")
struct MathOverlayPixelAlignmentTests {

    /// Any real font: the resample being measured is font-independent.
    private func loader(_ name: String) -> CGFont? {
        CTFontCopyGraphicsFont(CTFontCreateWithName("Helvetica" as CFString, 12, nil), nil)
    }

    /// A rule (fraction bar) plus a glyph, at an em width whose device-pixel
    /// extent is deliberately non-integral.
    private let json = """
        {"width":3.1415,"height":0.7,"depth":0.25,"items":[
          {"type":"Line","x":0.1,"y":0.35,"width":2.9,"thickness":0.05,
           "color":{"r":0,"g":0,"b":0,"a":1}},
          {"type":"GlyphPath","font":"Math-Italic","char_code":120,"x":0.3,"y":0.65,
           "scale":1.0,"color":{"r":0,"g":0,"b":0,"a":1}}
        ]}
        """

    private func snap(_ v: CGFloat, _ scale: CGFloat) -> CGFloat { (v * scale).rounded() / scale }

    /// Draws `image` into a 2x bitmap at `rect`, the way a layout fragment does.
    private func rasterize(_ image: NSImage, at rect: CGRect,
                           canvas: CGSize = CGSize(width: 120, height: 60),
                           scale: CGFloat = 2) -> (px: [UInt8], w: Int, h: Int) {
        let w = Int(canvas.width * scale), h = Int(canvas.height * scale)
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            ctx.scaleBy(x: scale, y: scale)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            image.draw(in: rect, from: .zero, operation: .sourceOver,
                       fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        return (buf, w, h)
    }

    /// Sharpness, independent of where the image landed: `ink` (sum of alpha) is
    /// conserved by a resample, but `area` (pixels carrying any ink) grows and
    /// `full` (solid pixels) collapses as the blit smears.
    private func ink(_ r: (px: [UInt8], w: Int, h: Int)) -> (ink: Double, area: Int, full: Int) {
        var total = 0.0, area = 0, full = 0
        for i in stride(from: 3, to: r.px.count, by: 4) {
            let a = Int(r.px[i])
            guard a > 0 else { continue }
            total += Double(a) / 255
            area += 1
            if a == 255 { full += 1 }
        }
        return (total, area, full)
    }

    @Test("A device-aligned rect blits 1:1; a fractional size or origin does not")
    @MainActor func alignmentIsWhatKeepsTheBlitSharp() throws {
        let m = try #require(RaTeXDisplayListRenderer(fontLoader: loader)
            .render(json: json, pointSize: 16, color: .black, scale: 2))
        let rep = try #require(m.image.representations.first)
        let native = CGSize(width: CGFloat(rep.pixelsWide) / 2, height: CGFloat(rep.pixelsHigh) / 2)

        // The mismatch that starts it all: pixel count is rounded, point size is not.
        #expect(m.image.size != native)
        // …but snapping the point size onto the device grid recovers it exactly,
        // which is what `mathOverlay` does.
        #expect(snap(m.image.size.width, 2) == native.width)
        #expect(snap(m.image.size.height, 2) == native.height)

        let reference = ink(rasterize(m.image, at: CGRect(origin: .zero, size: native)))
        // Fixed: snapped size at a snapped origin — as sharp as a 1:1 blit.
        let fixed = ink(rasterize(m.image, at: CGRect(x: snap(10.37, 2), y: snap(20.63, 2),
                                                     width: snap(m.image.size.width, 2),
                                                     height: snap(m.image.size.height, 2))))
        #expect(fixed.area == reference.area)
        #expect(fixed.full == reference.full)

        // Each half alone is not enough: the ink is conserved but smeared.
        let fractionalOrigin = ink(rasterize(m.image, at: CGRect(origin: CGPoint(x: 10.37, y: 20.63),
                                                                size: native)))
        let fractionalSize = ink(rasterize(m.image, at: CGRect(origin: CGPoint(x: 10, y: 20),
                                                              size: m.image.size)))
        for smeared in [fractionalOrigin, fractionalSize] {
            #expect(abs(smeared.ink - reference.ink) < 1)          // same ink…
            #expect(Double(smeared.area) > Double(reference.area) * 1.2)  // …over ≥20% more pixels
            #expect(smeared.full < reference.full / 2)             // and barely any solid pixels
        }
    }

    /// Same check against the real engine and real equations, when the RaTeX
    /// extension happens to be installed (skips in CI and on a clean machine).
    @Test("Real RaTeX equations blit 1:1 once snapped")
    @MainActor func realEquations() throws {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Edmund/Math/ratex-\(RaTeXRelease.version)", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("ratex_wasm.js").path)
        else { return }
        let host = WasmMathHost()
        host.load(dir: dir)
        try #require(host.isLoaded)

        for latex in ["x^2 + y^2 = z^2", "\\frac{a}{b}", "\\sum_{i=1}^{n} i^2",
                      "\\int_0^\\infty e^{-x^2}\\,dx = \\frac{\\sqrt{\\pi}}{2}"] {
            guard let m = host.render(latex: latex, displayMode: false,
                                      pointSize: 14, color: .black),
                  let rep = m.image.representations.first else { continue }
            let native = CGSize(width: CGFloat(rep.pixelsWide) / 2,
                                height: CGFloat(rep.pixelsHigh) / 2)
            let canvas = CGSize(width: m.image.size.width + 40, height: m.image.size.height + 40)
            let reference = ink(rasterize(m.image, at: CGRect(x: 10, y: 12, width: native.width,
                                                             height: native.height), canvas: canvas))
            let fixed = ink(rasterize(m.image, at: CGRect(x: snap(10.37, 2), y: snap(12.63, 2),
                                                          width: snap(m.image.size.width, 2),
                                                          height: snap(m.image.size.height, 2)),
                                      canvas: canvas))
            let old = ink(rasterize(m.image, at: CGRect(x: 10.37, y: 12.63,
                                                        width: m.image.size.width,
                                                        height: m.image.size.height),
                                    canvas: canvas))
            #expect(fixed.area == reference.area, "\(latex): fixed draw ≠ Read mode's footprint")
            #expect(fixed.full == reference.full, "\(latex)")
            #expect(old.area > reference.area, "\(latex): the old draw should be the smeared one")
        }
    }
}
