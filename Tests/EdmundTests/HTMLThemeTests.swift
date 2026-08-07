import Testing
import AppKit
@testable import EdmundCore

@Suite("HTMLTheme — CSS emission")
@MainActor
struct HTMLThemeTests {

    private func css(dark: Bool) -> String {
        let theme = EditorTheme(fontName: "Iowan Old Style", fontSize: 16,
                                linkBlueHex: "#3366E6", codeHex: "#8A2425",
                                lineSpacing: 4, paragraphSpacingBefore: 2)
        return HTMLTheme.css(theme, callouts: Callout.defaultStyles, dark: dark)
    }

    @Test("Derives custom properties from the theme")
    func vars() {
        let out = css(dark: false)
        #expect(out.contains("--accent: #3366E6;"))
        #expect(out.contains("--code: #8A2425;"))
        #expect(out.contains("--body-size: 16px;"))
        // Natural line height is measured from the font, not assumed: derive the
        // expectation the same way rather than pinning a literal that silently
        // encodes whichever body face happens to be installed.
        let font = NSFont(name: "Iowan Old Style", size: 16) ?? .systemFont(ofSize: 16)
        let expected = (NSLayoutManager().defaultLineHeight(for: font) + 4) / 16
        #expect(out.contains("--line-height: \(String(format: "%g", expected));"))
        // …and it must be materially looser than the old hardcoded 1.2 base,
        // which is what made Read mode ~11% tighter than the editor.
        #expect(expected > 1.5)
        // Multi-word family is quoted with a fallback stack.
        #expect(out.contains("\"Iowan Old Style\""))
    }

    @Test("Cascade scripts emit @font-face local() blocks and lead the body stack")
    func cascadeBlocks() {
        var theme = EditorTheme(fontName: "Iowan Old Style", fontSize: 16,
                                linkBlueHex: "#3366E6", codeHex: "#8A2425",
                                lineSpacing: 4, paragraphSpacingBefore: 2)
        theme.fontCascade = [.han: "Songti SC", .emoji: "Apple Color Emoji"]
        let out = HTMLTheme.css(theme, callouts: Callout.defaultStyles, dark: false)
        #expect(out.contains(
            "@font-face { font-family: \"edmund-cascade-han\"; src: local(\"Songti SC\");"))
        #expect(out.contains(
            "@font-face { font-family: \"edmund-cascade-emoji\"; src: local(\"Apple Color Emoji\");"))
        // The cascade families lead the body stack, ahead of the body family.
        #expect(out.contains(
            "--body-font: \"edmund-cascade-emoji\", \"edmund-cascade-han\", \"Iowan Old Style\", -apple-system, serif;"))
        // The Han block carries the script's unicode-range fence.
        #expect(out.contains("unicode-range: U+3005, U+3400-4DBF, U+4E00-9FFF"))
    }

    @Test("No cascade emits no @font-face blocks and the stack is unchanged")
    func noCascadeNoBlocks() {
        let out = css(dark: false)
        #expect(!out.contains("@font-face"))
        #expect(!out.contains("edmund-cascade"))
        #expect(out.contains("--body-font: \"Iowan Old Style\", -apple-system, serif;"))
    }

    /// Read mode and Edit mode must paint text — and the math bitmaps that flow
    /// with it — in the identical ink. They used to disagree in light mode (Read
    /// mode hard-coded #1a1a1a against the editor's `textColor`), which made the
    /// same equation visibly lighter in Read mode.
    @Test("--fg is the editor's own body ink, in both appearances")
    func bodyInkMatchesEditor() {
        for dark in [false, true] {
            let ink = EditorTheme.bodyTextColorResolved(dark: dark).hexString
            #expect(css(dark: dark).contains("--fg: \(ink);"))
        }
        // Light mode is the system text color (pure black in Aqua); dark mode is
        // the softened near-white, because `textColor`'s pure white glares on
        // the #292929 page.
        #expect(EditorTheme.bodyTextColorResolved(dark: false).hexString == "#000000")
        #expect(EditorTheme.bodyTextColorResolved(dark: true).hexString == "#E6E6E6")
    }

    @Test("Reading column max-width matches the editor's physical cap; uncapped by default")
    func pageMaxWidth() {
        let theme = EditorTheme(fontName: "Iowan Old Style", fontSize: 16,
                                linkBlueHex: "#3366E6", codeHex: "#8A2425",
                                lineSpacing: 4, paragraphSpacingBefore: 2)
        let capped = HTMLTheme.css(theme, callouts: Callout.defaultStyles, dark: false,
                                   maxContentWidthPoints: 340)
        #expect(capped.contains("--page-max-width: 340px;"))

        let uncapped = HTMLTheme.css(theme, callouts: Callout.defaultStyles, dark: false)
        #expect(uncapped.contains("--page-max-width: none;"))
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
        #expect(css(dark: true).contains("--bg: #292929;"))
    }

    @Test("Wide tables scroll horizontally instead of wrapping cell text")
    func tableScrolls() {
        let out = css(dark: false)
        #expect(out.contains(".table-wrap { overflow-x: auto; margin: 1em 0; }"))
        #expect(!out.contains("overflow-wrap"))
    }

    @Test("Emits code token colors from the shared palette, per appearance")
    func codeTokenColors() {
        let light = css(dark: false)
        #expect(light.contains("pre code .tok-keyword { color: \(CodeSyntaxPalette.hex(.keyword, dark: false)); }"))
        #expect(light.contains("pre code { color: \(CodeSyntaxPalette.hex(nil, dark: false)); }"))
        let dark = css(dark: true)
        #expect(dark.contains("pre code .tok-string { color: \(CodeSyntaxPalette.hex(.string, dark: true)); }"))
        // The palettes differ between appearances.
        #expect(CodeSyntaxPalette.hex(.keyword, dark: false) != CodeSyntaxPalette.hex(.keyword, dark: true))
    }
}
