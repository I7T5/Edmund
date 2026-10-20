import Testing
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

    @Test("Light and dark pages paint different backgrounds")
    @MainActor func appearance() {
        let light = QuickLookPage.html(markdown: "text", baseURL: nil, dark: false)
        let dark = QuickLookPage.html(markdown: "text", baseURL: nil, dark: true)
        #expect(bgLine(light) != nil)
        #expect(bgLine(light) != bgLine(dark))
    }
}
