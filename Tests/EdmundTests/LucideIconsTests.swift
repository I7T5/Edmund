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

    @Test func checkboxSVGShapes() {
        #expect(LucideIcons.checkboxSVG(checked: true).contains("fill=\"currentColor\""))
        #expect(LucideIcons.checkboxSVG(checked: true).contains("stroke=\"#fff\""))
        #expect(LucideIcons.checkboxSVG(checked: false).contains("stroke=\"currentColor\""))
        #expect(!LucideIcons.checkboxSVG(checked: false).contains("fill=\"currentColor\""))
    }
}
