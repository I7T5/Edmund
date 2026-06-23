import Testing
import AppKit
@testable import EdmundCore

@Suite("HTMLTheme — CSS emission")
@MainActor
struct HTMLThemeTests {

    private func css(dark: Bool) -> String {
        let theme = EditorTheme(fontName: "Iowan Old Style", fontSize: 16,
                                accentHex: "#3366E6", codeHex: "#8A2425",
                                lineSpacing: 4, paragraphSpacingBefore: 2)
        return HTMLTheme.css(theme, callouts: Callout.defaultStyles, dark: dark)
    }

    @Test("Derives custom properties from the theme")
    func vars() {
        let out = css(dark: false)
        #expect(out.contains("--accent: #3366E6;"))
        #expect(out.contains("--code: #8A2425;"))
        #expect(out.contains("--body-size: 16px;"))
        // 1.2 + 4/16 = 1.45
        #expect(out.contains("--line-height: 1.45;"))
        // Multi-word family is quoted with a fallback stack.
        #expect(out.contains("\"Iowan Old Style\""))
    }

    @Test("Emits per-callout-type colors with derived rgba background")
    func calloutVars() {
        let out = css(dark: false)
        #expect(out.contains(".callout-note {"))
        #expect(out.contains("--c-accent: #086DDD;"))
        // note's background is derived from the accent at backgroundAlpha 0.08.
        #expect(out.contains("rgba(8, 109, 221, 0.08)"))
    }

    @Test("Dark appearance picks dark color variants")
    func darkVariant() {
        // 'caution' has darkColorHex #F85149.
        #expect(css(dark: true).contains("--c-accent: #F85149;"))
        #expect(css(dark: false).contains("--c-accent: #CF222E;"))
        #expect(css(dark: true).contains("--bg: #1e1e1e;"))
    }
}
