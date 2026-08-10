import AppKit
import CoreText

// MARK: - RaTeX DisplayList → NSImage
//
// RaTeX's WASM (`renderLatex`) returns a "display list" JSON — the same
// intermediate every RaTeX binding consumes (docs/DISPLAYLIST_JSON_PROTOCOL.md).
// It does NOT contain rasterized pixels or glyph outlines; it references glyphs
// by font name + Unicode code point, plus rule lines. We rasterize it ourselves
// with CoreText + the KaTeX fonts, which keeps the shipped app Swift-only (the
// WASM is sandboxed data) and gives us the exact ascent/descent the overlay
// model needs — no dependency on RaTeX's own renderer or a DOM/canvas.
//
// Coordinates are in em (multiply by point size). The box origin is top-left,
// y increases downward; a glyph's `y` is its baseline. `height` is the ascent
// (baseline sits at y = height) and `depth` is the descent.

/// Decoded RaTeX display list. Only the fields we render are modeled; unknown
/// item types decode to `.unknown` and are skipped.
struct RaTeXDisplayList: Decodable {
    let width: Double
    let height: Double   // ascent (em); baseline at y = height
    let depth: Double    // descent (em)
    let items: [Item]

    struct RGBA: Decodable { let r, g, b, a: Double }

    /// One segment of a `Path` item. Coordinates are offsets (em) from the
    /// item's own origin, in the same top-down space as everything else.
    enum PathCommand: Decodable {
        case move(x: Double, y: Double)
        case line(x: Double, y: Double)
        case cubic(x1: Double, y1: Double, x2: Double, y2: Double, x: Double, y: Double)
        case quad(x1: Double, y1: Double, x: Double, y: Double)
        case close
        case unknown

        private enum Keys: String, CodingKey { case type, x, y, x1, y1, x2, y2 }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            switch try c.decode(String.self, forKey: .type) {
            case "MoveTo":
                self = .move(x: try c.decode(Double.self, forKey: .x),
                             y: try c.decode(Double.self, forKey: .y))
            case "LineTo":
                self = .line(x: try c.decode(Double.self, forKey: .x),
                             y: try c.decode(Double.self, forKey: .y))
            case "CubicTo":
                self = .cubic(x1: try c.decode(Double.self, forKey: .x1),
                              y1: try c.decode(Double.self, forKey: .y1),
                              x2: try c.decode(Double.self, forKey: .x2),
                              y2: try c.decode(Double.self, forKey: .y2),
                              x: try c.decode(Double.self, forKey: .x),
                              y: try c.decode(Double.self, forKey: .y))
            case "QuadTo":
                self = .quad(x1: try c.decode(Double.self, forKey: .x1),
                             y1: try c.decode(Double.self, forKey: .y1),
                             x: try c.decode(Double.self, forKey: .x),
                             y: try c.decode(Double.self, forKey: .y))
            case "Close":
                self = .close
            default:
                self = .unknown
            }
        }
    }

    enum Item: Decodable {
        case glyph(font: String, charCode: Int, x: Double, y: Double, scale: Double, color: RGBA)
        case line(x: Double, y: Double, width: Double, thickness: Double, color: RGBA)
        case rect(x: Double, y: Double, width: Double, height: Double, color: RGBA)
        case path(x: Double, y: Double, commands: [PathCommand], fill: Bool, color: RGBA)
        case unknown

        private enum Keys: String, CodingKey {
            case type, font, char_code, x, y, scale, color, width, thickness, height, commands, fill
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            switch try c.decode(String.self, forKey: .type) {
            case "GlyphPath":
                self = .glyph(font: try c.decode(String.self, forKey: .font),
                              charCode: try c.decode(Int.self, forKey: .char_code),
                              x: try c.decode(Double.self, forKey: .x),
                              y: try c.decode(Double.self, forKey: .y),
                              scale: try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1,
                              color: try c.decode(RGBA.self, forKey: .color))
            case "Line":
                self = .line(x: try c.decode(Double.self, forKey: .x),
                             y: try c.decode(Double.self, forKey: .y),
                             width: try c.decode(Double.self, forKey: .width),
                             thickness: try c.decode(Double.self, forKey: .thickness),
                             color: try c.decode(RGBA.self, forKey: .color))
            case "Rect":
                self = .rect(x: try c.decode(Double.self, forKey: .x),
                             y: try c.decode(Double.self, forKey: .y),
                             width: try c.decode(Double.self, forKey: .width),
                             height: try c.decode(Double.self, forKey: .height),
                             color: try c.decode(RGBA.self, forKey: .color))
            case "Path":
                self = .path(x: try c.decode(Double.self, forKey: .x),
                             y: try c.decode(Double.self, forKey: .y),
                             commands: try c.decode([PathCommand].self, forKey: .commands),
                             fill: try c.decodeIfPresent(Bool.self, forKey: .fill) ?? true,
                             color: try c.decode(RGBA.self, forKey: .color))
            default:
                self = .unknown
            }
        }
    }
}

/// Rasterizes a RaTeX display list to an `NSImage` + baseline metrics. The KaTeX
/// fonts are supplied by an injected loader (production loads them from the
/// installed extension directory; tests point it at a fixture directory).
@MainActor
final class RaTeXDisplayListRenderer {
    /// Maps a RaTeX font name ("Math-Italic") to a `CGFont`, or nil if missing.
    private let fontLoader: (String) -> CGFont?
    /// Extra pixels of transparent inset so a glyph's ink overshoot isn't
    /// clipped at the image edge (mirrors the SwiftMath path's inset).
    private let insetPad: CGFloat = 2

    init(fontLoader: @escaping (String) -> CGFont?) {
        self.fontLoader = fontLoader
    }

    /// Renders `json` (a RaTeX display list) at `pointSize`, tinting every item
    /// to `color` (so the render cache can stay keyed by color for light/dark).
    /// Returns nil on decode failure or empty output.
    func render(json: String, pointSize: CGFloat, color: NSColor, scale: CGFloat) -> RenderedMath? {
        guard let data = json.data(using: .utf8),
              let dl = try? JSONDecoder().decode(RaTeXDisplayList.self, from: data) else { return nil }

        let fs = pointSize
        let boxW = CGFloat(dl.width) * fs
        let boxH = CGFloat(dl.height + dl.depth) * fs
        guard boxW > 0, boxH > 0 else { return nil }

        let pxW = Int(((boxW) * scale).rounded()) + Int((insetPad * 2 * scale).rounded())
        let pxH = Int(((boxH) * scale).rounded()) + Int((insetPad * 2 * scale).rounded())
        guard let ctx = CGContext(data: nil, width: max(1, pxW), height: max(1, pxH),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        // A raw CGBitmapContext (not backed by a window/NSGraphicsContext)
        // defaults antialiasing and font smoothing OFF — unlike SwiftMath's
        // path, which renders through higher-level Cocoa APIs that don't have
        // this problem. Without these, glyphs come out visibly softer/thinner
        // than on-screen text elsewhere in the app.
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldSmoothFonts(true)
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSubpixelPositionFonts(true)
        ctx.setAllowsFontSubpixelPositioning(true)

        // Work in a y-up context (CG default). Do NOT flip — flipping the context
        // draws glyphs upside down. Convert the display list's top-down y to y-up
        // via boxH - y. `insetPad` shifts everything in by the transparent margin.
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: insetPad, y: insetPad)
        let fill = (color.usingColorSpace(.deviceRGB) ?? color).cgColor

        for item in dl.items {
            switch item {
            case let .glyph(font, charCode, x, y, glyphScale, _):
                guard let cgFont = fontLoader(font), let scalar = UnicodeScalar(charCode) else { continue }
                let ctFont = CTFontCreateWithGraphicsFont(cgFont, fs * CGFloat(glyphScale), nil, nil)
                var utf16 = Array(String(scalar).utf16)
                var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
                guard CTFontGetGlyphsForCharacters(ctFont, &utf16, &glyphs, utf16.count),
                      glyphs[0] != 0 else { continue }
                ctx.saveGState()
                ctx.setFillColor(fill)
                var pos = CGPoint(x: CGFloat(x) * fs, y: boxH - CGFloat(y) * fs)
                CTFontDrawGlyphs(ctFont, &glyphs, &pos, 1, ctx)
                ctx.restoreGState()

            case let .line(x, y, width, thickness, _):
                ctx.setFillColor(fill)
                let th = CGFloat(thickness) * fs
                ctx.fill(CGRect(x: CGFloat(x) * fs, y: boxH - CGFloat(y) * fs - th / 2,
                                width: CGFloat(width) * fs, height: th))

            case let .rect(x, y, width, height, _):
                ctx.setFillColor(fill)
                ctx.fill(CGRect(x: CGFloat(x) * fs, y: boxH - CGFloat(y + height) * fs,
                                width: CGFloat(width) * fs, height: CGFloat(height) * fs))

            case let .path(x, y, commands, filled, _):
                drawPath(commands, originX: CGFloat(x) * fs, originY: CGFloat(y) * fs,
                         filled: filled, fs: fs, boxH: boxH, color: fill, in: ctx)

            case .unknown:
                continue
            }
        }

        guard let cgImage = ctx.makeImage() else { return nil }
        // NSImage sized in points, backed by a 2x/3x rep so it stays crisp; the
        // inset is included in the point size on both axes.
        let pointSizeBox = NSSize(width: boxW + insetPad * 2, height: boxH + insetPad * 2)
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = pointSizeBox
        let image = NSImage(size: pointSizeBox)
        image.addRepresentation(rep)

        // The inset was added symmetrically; fold the bottom half into descent so
        // the baseline placement is unchanged (same trick as the SwiftMath path).
        return RenderedMath(image: image,
                            ascent: CGFloat(dl.height) * fs + insetPad,
                            descent: CGFloat(dl.depth) * fs + insetPad)
    }

    /// Draws a `Path` item — the vector half of the display list, and the only
    /// thing that draws a *stretchy* delimiter's connecting stem (a tall
    /// `\begin{Bmatrix}` brace is Size4 glyph pieces bridged by path bars, and
    /// a tall `\left(` is path outline only, no glyph at all). Command
    /// coordinates are em offsets from the item's origin in the same top-down
    /// space as everything else, so each point flips into the y-up context the
    /// way a glyph baseline does.
    ///
    /// Each subpath (a run starting at a `MoveTo`) is filled on its own, with
    /// the even-odd rule. Both quirks are copied from RaTeX's own reference
    /// renderer, and both have a reason there: KaTeX assembles stretchy arrows
    /// from components whose winding directions oppose, so one combined nonzero
    /// fill cancels the shaft away, and a tall delimiter's stem is a second
    /// subpath that nonzero would double-fill.
    private func drawPath(_ commands: [RaTeXDisplayList.PathCommand],
                          originX: CGFloat, originY: CGFloat,
                          filled: Bool, fs: CGFloat, boxH: CGFloat,
                          color: CGColor, in ctx: CGContext) {
        func pt(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: originX + CGFloat(x) * fs, y: boxH - originY - CGFloat(y) * fs)
        }

        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setFillColor(color)
        ctx.setStrokeColor(color)
        // RaTeX's renderers stroke with a device-pixel constant (1.5px); 0.04em
        // is KaTeX's default rule thickness, so an unfilled path keeps the
        // weight of `\frac`'s bar at every point size instead of thinning out.
        ctx.setLineWidth(0.04 * fs)

        var segment = CGMutablePath()
        func flush() {
            guard !segment.isEmpty else { return }
            ctx.addPath(segment)
            if filled { ctx.fillPath(using: .evenOdd) } else { ctx.strokePath() }
            segment = CGMutablePath()
        }

        for cmd in commands {
            switch cmd {
            case let .move(x, y):
                flush()
                segment.move(to: pt(x, y))
            // A subpath that never opened with a MoveTo has no current point;
            // CoreGraphics treats that as a programming error, so skip it.
            case let .line(x, y):
                guard !segment.isEmpty else { continue }
                segment.addLine(to: pt(x, y))
            case let .cubic(x1, y1, x2, y2, x, y):
                guard !segment.isEmpty else { continue }
                segment.addCurve(to: pt(x, y), control1: pt(x1, y1), control2: pt(x2, y2))
            case let .quad(x1, y1, x, y):
                guard !segment.isEmpty else { continue }
                segment.addQuadCurve(to: pt(x, y), control: pt(x1, y1))
            case .close:
                guard !segment.isEmpty else { continue }
                segment.closeSubpath()
            case .unknown:
                continue
            }
        }
        flush()
    }
}
