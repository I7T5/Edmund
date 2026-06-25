import Testing
import AppKit
@testable import EdmundCore

@Suite("DocumentHTML — assembly & asset inlining")
@MainActor
struct DocumentHTMLTests {

    private func doc(_ md: String, dark: Bool = false) -> String {
        DocumentHTML.full(markdown: md, theme: .default,
                          callouts: Callout.defaultStyles, dark: dark)
    }

    @Test("Wraps body in a full self-contained document")
    func wrapper() {
        let out = doc("# Hi")
        #expect(out.hasPrefix("<!DOCTYPE html>"))
        #expect(out.contains("<style>"))
        #expect(out.contains("<div class=\"page\"><h1>Hi</h1></div>"))
    }

    @Test("Callout icon placeholder becomes an inlined PNG data URI")
    func calloutIcon() {
        let out = doc("> [!note]\n> body")
        #expect(!out.contains("data-symbol"))   // placeholder consumed
        #expect(out.contains("<span class=\"callout-icon\"><img src=\"data:image/png;base64,"))
    }

    @Test("Inline math placeholder becomes an inlined image with baseline align")
    func inlineMath() {
        let out = doc("value $x^2$ here")
        #expect(!out.contains("data-tex"))
        #expect(out.contains("<img class=\"math math-inline\""))
        #expect(out.contains("vertical-align:"))
        #expect(out.contains("src=\"data:image/png;base64,"))
    }

    @Test("Display math placeholder becomes a centered image")
    func displayMath() {
        let out = doc("$$\nx^2\n$$")
        #expect(out.contains("<div class=\"math-display\"><img class=\"math\""))
        #expect(out.contains("src=\"data:image/png;base64,"))
    }

    @Test("Unparseable math falls back to showing the source")
    func mathFallback() {
        let out = doc("bad $\\frac{$ math")
        #expect(out.contains("<code>\\frac{</code>"))
    }

    // MARK: Images

    @Test("Local image is read and inlined as a data URI")
    func localImageInlined() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("edmund-img-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // The file's bytes are irrelevant to the inlining path; an 8-byte PNG
        // signature is enough to exercise read + base64 + MIME-by-extension.
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        try png.write(to: dir.appendingPathComponent("pic.png"))

        let out = DocumentHTML.full(markdown: "![cat](pic.png)", theme: .default,
                                    callouts: Callout.defaultStyles, dark: false,
                                    baseURL: dir)
        #expect(!out.contains("data-src"))   // placeholder consumed
        #expect(out.contains("<img class=\"md-image\" src=\"data:image/png;base64,"))
        #expect(out.contains("alt=\"cat\""))
    }

    @Test("Unresolvable local image falls back to alt only (no src)")
    func missingImage() {
        let out = doc("![gone](nope.png)")   // no baseURL → can't resolve
        #expect(out.contains("<img class=\"md-image\" alt=\"gone\">"))
        #expect(!out.contains("src="))
    }

    @Test("Remote image is suppressed by default, emitted when opted in")
    func remoteImagePolicy() {
        let md = "![r](https://example.com/x.png)"
        let off = DocumentHTML.full(markdown: md, theme: .default,
                                    callouts: Callout.defaultStyles, dark: false)
        #expect(off.contains("<img class=\"md-image\" alt=\"r\">"))
        #expect(!off.contains("https://example.com/x.png"))

        let on = DocumentHTML.full(markdown: md, theme: .default,
                                   callouts: Callout.defaultStyles, dark: false,
                                   options: ReadRenderOptions(allowRemoteImages: true))
        #expect(on.contains("src=\"https://example.com/x.png\""))
    }
}
