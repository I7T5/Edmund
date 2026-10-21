import Testing
import AppKit
@testable import EdmundCore

@Suite("QuickLookPage")
struct QuickLookPageTests {

    private func bgLine(_ html: String) -> Substring? {
        html.split(separator: "\n").first { $0.contains("--bg:") }
    }

    @Test("The page uses the 13pt Quick Look theme, tight margins and 1em bullets")
    @MainActor func quickLookStyle() {
        let html = QuickLookPage.html(markdown: "- item", baseURL: nil, dark: false)
        #expect(html.contains("--body-size: 13px"))
        #expect(html.contains("body { padding: 12px 14px; }"))
        #expect(html.contains("ul > li::marker { font-size: 1em; }"))
        #expect(html.contains("<li>"))
    }

    /// Fraction of `rect`'s pixels darker than mid-gray.
    private func inkFraction(_ image: CGImage, in rect: CGRect) -> Double {
        let rep = NSBitmapImageRep(cgImage: image)
        var dark = 0, total = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                total += 1
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                   (c.redComponent + c.greenComponent + c.blueComponent) / 3 < 0.5 { dark += 1 }
            }
        }
        return Double(dark) / Double(max(total, 1))
    }

    @Test("The thumbnail is a white page with the text drawn from the top left")
    @MainActor func thumbnailPage() throws {
        let size = CGSize(width: 400, height: 518)
        let image = try #require(QuickLookPage.thumbnail(
            markdown: "# Heading\n\nSome **bold** body text that runs on for a while.",
            baseURL: nil, pixelSize: size))
        #expect(image.width == 400 && image.height == 518)
        // The heading sits just inside the 28pt margin (bitmap rows run top-down).
        #expect(inkFraction(image, in: CGRect(x: 28, y: 28, width: 150, height: 30)) > 0.02)
        #expect(inkFraction(image, in: CGRect(x: 0, y: 0, width: 400, height: 20)) == 0)
        #expect(inkFraction(image, in: CGRect(x: 300, y: 400, width: 100, height: 118)) == 0)
    }

    @Test("Tables and math still produce a thumbnail")
    @MainActor func thumbnailRichContent() {
        let md = "| a | b |\n| - | - |\n| 1 | 2 |\n\n$$x^2 + y^2$$\n"
        #expect(QuickLookPage.thumbnail(markdown: md, baseURL: nil,
                                        pixelSize: CGSize(width: 200, height: 259)) != nil)
    }

    @Test("Light and dark pages paint different backgrounds")
    @MainActor func appearance() {
        let light = QuickLookPage.html(markdown: "text", baseURL: nil, dark: false)
        let dark = QuickLookPage.html(markdown: "text", baseURL: nil, dark: true)
        #expect(bgLine(light) != nil)
        #expect(bgLine(light) != bgLine(dark))
    }
}
