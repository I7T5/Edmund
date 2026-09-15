import Testing
import AppKit
import CoreText
@testable import EdmundCore

// RaTeX's display list has four item types (its
// `docs/DISPLAYLIST_JSON_PROTOCOL.md`): GlyphPath, Line, Rect and Path. We used
// to decode only the first two and silently skip the rest, which is what issue
// #265 ("brackets are not rendering properly") actually was: a *stretchy*
// delimiter is not one glyph. A tall `\begin{Bmatrix}` brace is Size4 glyph
// pieces (U+23A7…U+23AD) bridged by Path bars, so it came out as disconnected
// fragments; a tall `\left(` is Path outline with no glyph at all, so it came
// out as nothing. Both are Edmund-side — RaTeX's JSON was correct all along.
//
// The JSON in these tests is real 0.1.14 output, not invented: the stem is the
// first Path of `\begin{Bmatrix} a \\ b \\ c \\ d \end{Bmatrix}`, and the curve
// is the shape of `\left(` around a 4-row matrix. No glyph items, so these need
// no fonts and run everywhere — and on the pre-fix renderer every one of them
// rasterizes to a completely blank image.

@Suite("RaTeX display list — Path and Rect items")
struct RaTeXPathItemTests {

    /// These display lists contain no glyphs, so the loader is never consulted.
    private func noFonts(_ name: String) -> CGFont? { nil }

    private let fs: CGFloat = 16
    private let insetPad: CGFloat = 2   // must match RaTeXDisplayListRenderer

    /// Ink bounding box in image pixels, measured from the top-left. A
    /// `CGBitmapContext`'s first memory row is the top of the image, so the row
    /// index is already top-down — the same direction the display list uses.
    private func inkBox(_ image: NSImage) throws -> (top: Int, bottom: Int, left: Int, right: Int, count: Int) {
        let rep = try #require(image.representations.first as? NSBitmapImageRep)
        let cg = try #require(rep.cgImage)
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var top = h, bottom = -1, left = w, right = -1, count = 0
        for row in 0..<h {
            for col in 0..<w where buf[(row * w + col) * 4 + 3] > 8 {
                top = min(top, row); bottom = max(bottom, row)
                left = min(left, col); right = max(right, col)
                count += 1
            }
        }
        return (top, bottom, left, right, count)
    }

    /// Where an em coordinate in the display list's top-down space lands, in
    /// image pixels from the top, at `scale` 1.
    private func expectedRow(_ yEm: Double, boxH: CGFloat, pxH: Int) -> Double {
        Double(pxH) - (Double(boxH) - yEm * Double(fs) + Double(insetPad))
    }

    @Test("A filled Path draws, and lands where the display list puts it")
    @MainActor func filledPathGeometry() throws {
        // First stem of a 4-row `Bmatrix`: item origin y = 1.50799, commands
        // spanning y −0.61598…0 and x 0.384…0.504 — so the bar occupies
        // y 0.89201…1.50799 em, x 0.384…0.504 em, top-down.
        let json = """
            {"width":2.30637,"height":2.65,"depth":2.15,"items":[
              {"type":"Path","x":0.0,"y":1.50799,"fill":true,
               "color":{"r":0,"g":0,"b":0,"a":1},
               "commands":[{"type":"MoveTo","x":0.384,"y":-0.61598},
                           {"type":"LineTo","x":0.504,"y":-0.61598},
                           {"type":"LineTo","x":0.504,"y":0.0},
                           {"type":"LineTo","x":0.384,"y":0.0},
                           {"type":"Close"}]}
            ]}
            """
        let m = try #require(RaTeXDisplayListRenderer(fontLoader: noFonts)
            .render(json: json, pointSize: fs, color: .black, scale: 1))
        let box = try inkBox(m.image)
        #expect(box.count > 0, "a Path item drew nothing — the item type is being skipped again")

        let rep = try #require(m.image.representations.first as? NSBitmapImageRep)
        let boxH = CGFloat(2.65 + 2.15) * fs
        // Top-down: the smaller em y is the *upper* edge, i.e. the smaller row.
        let wantTop = expectedRow(1.50799 - 0.61598, boxH: boxH, pxH: rep.pixelsHigh)
        let wantBottom = expectedRow(1.50799, boxH: boxH, pxH: rep.pixelsHigh)
        // A y-sign flip would mirror the bar to the far side of the box, which
        // is ~10 px away here — 1.5 px of antialiasing slack cannot hide it.
        #expect(abs(Double(box.top) - wantTop) < 1.5, "ink top \(box.top), expected ~\(wantTop)")
        #expect(abs(Double(box.bottom) - wantBottom) < 1.5, "ink bottom \(box.bottom), expected ~\(wantBottom)")
        #expect(abs(Double(box.left) - (0.384 * Double(fs) + Double(insetPad))) < 1.5)
        #expect(abs(Double(box.right) - (0.504 * Double(fs) + Double(insetPad))) < 1.5)
    }

    @Test("A curved Path draws — a tall `\\left(` is outline only, no glyph")
    @MainActor func cubicPathDraws() throws {
        let json = """
            {"width":2.279,"height":2.65,"depth":2.168,"items":[
              {"type":"Path","x":0.0,"y":4.8,"fill":true,
               "color":{"r":0,"g":0,"b":0,"a":1},
               "commands":[{"type":"MoveTo","x":0.863,"y":-4.791},
                           {"type":"CubicTo","x1":0.562,"y1":-4.487,"x2":0.409,"y2":-4.1,"x":0.347,"y":-3.62},
                           {"type":"CubicTo","x1":0.313,"y1":-3.457,"x2":0.311,"y2":-3.063,"x":0.311,"y":-1.719},
                           {"type":"CubicTo","x1":0.388,"y1":-0.737,"x2":0.545,"y2":-0.315,"x":0.805,"y":0.0},
                           {"type":"LineTo","x":0.863,"y":-0.009},
                           {"type":"Close"}]}
            ]}
            """
        let m = try #require(RaTeXDisplayListRenderer(fontLoader: noFonts)
            .render(json: json, pointSize: fs, color: .black, scale: 1))
        let box = try inkBox(m.image)
        #expect(box.count > 0, "a curved Path drew nothing")
        // The delimiter spans nearly the whole box height; a stray flattening to
        // a straight line or a dropped curve segment would collapse that.
        #expect(box.bottom - box.top > Int(4.0 * fs))
    }

    @Test("A Rect item draws at its top-left origin")
    @MainActor func rectDraws() throws {
        let json = """
            {"width":2.0,"height":1.0,"depth":0.5,"items":[
              {"type":"Rect","x":0.25,"y":0.5,"width":1.0,"height":0.25,
               "color":{"r":0,"g":0,"b":0,"a":1}}
            ]}
            """
        let m = try #require(RaTeXDisplayListRenderer(fontLoader: noFonts)
            .render(json: json, pointSize: fs, color: .black, scale: 1))
        let box = try inkBox(m.image)
        #expect(box.count > 0, "a Rect item drew nothing")

        let rep = try #require(m.image.representations.first as? NSBitmapImageRep)
        let boxH = CGFloat(1.0 + 0.5) * fs
        #expect(abs(Double(box.top) - expectedRow(0.5, boxH: boxH, pxH: rep.pixelsHigh)) < 1.5)
        #expect(abs(Double(box.bottom) - expectedRow(0.75, boxH: boxH, pxH: rep.pixelsHigh)) < 1.5)
    }

    @Test("An unknown item or path command is skipped, not fatal")
    @MainActor func forwardCompatibility() throws {
        // The protocol's own compatibility rule: decoders must ignore variants
        // they don't know rather than hard-fail the whole equation.
        let json = """
            {"width":1.0,"height":1.0,"depth":0.0,"items":[
              {"type":"SomethingNew","x":0.0,"y":0.0},
              {"type":"Path","x":0.0,"y":1.0,"fill":true,
               "color":{"r":0,"g":0,"b":0,"a":1},
               "commands":[{"type":"MoveTo","x":0.1,"y":-0.9},
                           {"type":"ArcTo","x":0.5,"y":-0.5},
                           {"type":"LineTo","x":0.9,"y":-0.9},
                           {"type":"LineTo","x":0.9,"y":0.0},
                           {"type":"Close"}]}
            ]}
            """
        let m = try #require(RaTeXDisplayListRenderer(fontLoader: noFonts)
            .render(json: json, pointSize: fs, color: .black, scale: 1))
        #expect(try inkBox(m.image).count > 0)
    }
}
