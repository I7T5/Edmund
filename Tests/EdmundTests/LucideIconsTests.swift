import Testing
import AppKit
@testable import EdmundCore

@Suite("LucideIcons")
struct LucideIconsTests {

    /// Every callout type's icon id must resolve to vendored geometry, plus the
    /// checkbox primitive `circle` — otherwise an icon renders blank.
    @Test func everyCalloutIconHasGeometry() {
        for style in Callout.defaultStyles.values {
            #expect(LucideIcons.geometry[style.iconName] != nil,
                    "missing geometry for \(style.iconName)")
        }
        #expect(LucideIcons.geometry["circle"] != nil)
    }

    @Test func inlineSVGCarriesCurrentColor() {
        let svg = LucideIcons.inlineSVG("info")
        #expect(svg?.contains("stroke=\"currentColor\"") == true)
        #expect(svg?.hasPrefix("<svg") == true)
        #expect(LucideIcons.inlineSVG("not-an-icon") == nil)
    }

    /// De-risks the platform SVG decoder: `NSImage(data:)` must actually
    /// rasterize the stroked markup (not return a blank image). Render a tinted
    /// icon and assert some pixels are opaque.
    @MainActor @Test func imageRendersNonBlank() throws {
        let image = try #require(LucideIcons.image("check", color: .red, pointSize: 32))
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
        NSGraphicsContext.restoreGraphicsState()

        var opaque = 0
        for x in 0..<32 where (try? rep.colorAt(x: x, y: 16)) != nil {
            if let c = rep.colorAt(x: x, y: 16), c.alphaComponent > 0.1 { opaque += 1 }
        }
        #expect(opaque > 0, "SVG decoded to a blank image — NSImage(data:) didn't render strokes")
    }

    /// Every vendored icon must parse into a stroked CGPath (the custom-title
    /// callout icon is drawn as a path, not an image), staying within the
    /// 24×24 viewBox (small slack for stroke geometry that touches the edge).
    @Test func everyIconParsesToPath() {
        for name in LucideIcons.geometry.keys {
            guard let path = LucideIcons.path(name) else {
                Issue.record("no path for \(name)"); continue
            }
            let box = path.boundingBoxOfPath
            #expect(box.minX >= -1 && box.minY >= -1 && box.maxX <= 25 && box.maxY <= 25,
                    "\(name) path escapes the viewBox: \(box)")
        }
        #expect(LucideIcons.path("not-an-icon") == nil)
    }

    /// Parser fidelity: for every icon, the stroked CGPath must rasterize to
    /// (nearly) the same pixels as the platform SVG decoder's rendering.
    /// Catches path-data parsing bugs — especially arc conversion — that a
    /// bounding-box check would miss. Compared by intersection-over-union of
    /// covered pixels; rasterizer/antialiasing differences keep it below 1.
    @MainActor @Test func pathMatchesSVGRendering() throws {
        let side = 48
        func coverage(_ draw: (CGContext) -> Void) -> [Bool] {
            let ctx = CGContext(data: nil, width: side, height: side,
                                bitsPerComponent: 8, bytesPerRow: side * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            draw(ctx)
            let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
            return (0..<(side * side)).map { data[$0 * 4 + 3] > 127 }
        }
        for name in LucideIcons.geometry.keys {
            let path = try #require(LucideIcons.path(name))
            let scale = CGFloat(side) / 24
            let pathPixels = coverage { ctx in
                // The path is in SVG's y-down space; the bitmap context is y-up.
                ctx.translateBy(x: 0, y: CGFloat(side))
                ctx.scaleBy(x: scale, y: -scale)
                ctx.addPath(path)
                ctx.setStrokeColor(NSColor.black.cgColor)
                ctx.setLineWidth(2)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                ctx.strokePath()
            }
            let image = try #require(LucideIcons.image(name, color: .black,
                                                       pointSize: CGFloat(side)))
            let svgPixels = coverage { ctx in
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
                NSGraphicsContext.restoreGraphicsState()
            }
            var intersection = 0, union = 0
            for i in 0..<(side * side) {
                if pathPixels[i] && svgPixels[i] { intersection += 1 }
                if pathPixels[i] || svgPixels[i] { union += 1 }
            }
            #expect(union > 0, "\(name): nothing rendered")
            let iou = union == 0 ? 0 : Double(intersection) / Double(union)
            #expect(iou > 0.6, "\(name): path raster diverges from SVG (IoU \(iou))")
        }
    }

    @Test func checkboxSVGShapes() {
        #expect(LucideIcons.checkboxSVG(checked: true).contains("fill=\"currentColor\""))
        #expect(LucideIcons.checkboxSVG(checked: true).contains("stroke=\"#fff\""))
        #expect(LucideIcons.checkboxSVG(checked: false).contains("stroke=\"currentColor\""))
        #expect(!LucideIcons.checkboxSVG(checked: false).contains("fill=\"currentColor\""))
    }
}
