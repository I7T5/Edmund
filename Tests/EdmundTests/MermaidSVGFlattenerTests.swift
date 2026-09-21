import Testing
import Foundation
@testable import EdmundCore

// The flattener is a pure string rewrite, so it is tested on hand-written
// fragments shaped like the library's output — no payload needed. What the
// full SVGs look like after flattening, and whether CoreSVG then draws them,
// is asserted in MermaidJSIntegrationTests (gated on the payload).
@Suite("Mermaid — SVG flattener for CoreSVG")
struct MermaidSVGFlattenerTests {

    private func svg(style: String = "--bg:#FFFFFF;--fg:#000000", css: String = "", body: String) -> String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10" style="\(style)">
        <style>
          svg { \(css) }
        </style>
        \(body)
        </svg>
        """
    }

    @Test("var() resolves from the <svg style> attribute, and nested through <style> declarations")
    func resolvesVariables() {
        let out = MermaidSVGFlattener.flatten(svg(
            css: "--_text: var(--fg);",
            body: ##"<rect fill="var(--bg)" stroke="var(--_text)"/>"##))
        #expect(out.contains(##"fill="#FFFFFF""##))
        #expect(out.contains(##"stroke="#000000""##))
        #expect(!out.contains("var("))
    }

    @Test("The <svg style> attribute wins over a <style> declaration of the same name")
    func attributeBeatsStyleBlock() {
        let out = MermaidSVGFlattener.flatten(svg(
            css: "--bg: #123456;",
            body: ##"<rect fill="var(--bg)"/>"##))
        #expect(out.contains(##"fill="#FFFFFF""##))
    }

    @Test("var() falls back when undefined, and an unresolvable var is left verbatim")
    func fallbacks() {
        let out = MermaidSVGFlattener.flatten(svg(
            body: ##"<rect fill="var(--missing, #ABCDEF)" stroke="var(--also-missing)"/>"##))
        #expect(out.contains(##"fill="#ABCDEF""##))
        #expect(out.contains(##"stroke="var(--also-missing)""##))
    }

    @Test("color-mix() in sRGB: one percentage, two, or none")
    func colorMix() {
        let out = MermaidSVGFlattener.flatten(svg(
            body: """
            <a fill="color-mix(in srgb, var(--fg) 25%, var(--bg))"/>
            <b fill="color-mix(in srgb, #000000 20%, #FFFFFF 80%)"/>
            <c fill="color-mix(in srgb, #000000, #FFFFFF)"/>
            """))
        #expect(out.contains(##"<a fill="#BFBFBF""##))   // 25% black on white
        #expect(out.contains(##"<b fill="#CCCCCC""##))   // 20/80
        #expect(out.contains(##"<c fill="#808080""##))   // 50/50
    }

    @Test("The library's real declaration shape resolves: fallback holding a color-mix of vars")
    func libraryShapedDeclaration() {
        let out = MermaidSVGFlattener.flatten(svg(
            css: "--_line: var(--line, color-mix(in srgb, var(--fg) 50%, var(--bg)));",
            body: ##"<polyline stroke="var(--_line)" points="0,0 1,1"/>"##))
        #expect(out.contains(##"stroke="#808080""##))
    }

    @Test("Rules inside <style> are rewritten too, so class-styled shapes get literal colours")
    func styleBlockRules() {
        let out = MermaidSVGFlattener.flatten(svg(
            css: "--_muted: color-mix(in srgb, var(--fg) 40%, var(--bg));",
            body: "<style>.label { fill: var(--_muted); }</style><text class=\"label\">x</text>"))
        #expect(out.contains(".label { fill: #999999; }"))
    }

    @Test("marker-end on a polyline becomes the marker's shape, translated to the end point and rotated to face forward")
    func inlinesEndMarker() {
        let out = MermaidSVGFlattener.flatten(svg(body: """
            <defs>
              <marker id="arrowhead" markerWidth="8" markerHeight="5" refX="7" refY="2.5" orient="auto">
                <polygon points="0 0, 8 2.5, 0 5" fill="#000000" />
              </marker>
            </defs>
            <polyline points="10,20 10,60" fill="none" stroke="#000000" stroke-width="1" marker-end="url(#arrowhead)" />
            """))
        #expect(!out.contains("marker-end"))
        #expect(!out.contains("<marker"))
        #expect(!out.contains("<defs>"))
        // Heading straight down: +90°. Translate to the end point, un-offset by ref.
        #expect(out.contains(##"<g transform="translate(10.000,60.000) rotate(90.000) scale(1) translate(-7,-2.5)">"##))
        #expect(out.contains(##"<polygon points="0 0, 8 2.5, 0 5" fill="#000000" />"##))
    }

    @Test("marker-start with auto-start-reverse faces back along the line; markerUnits scale with stroke width")
    func startMarkerAndStrokeScale() {
        let out = MermaidSVGFlattener.flatten(svg(body: """
            <defs>
              <marker id="arrowhead-start" markerWidth="8" markerHeight="5" refX="1" refY="2.5" orient="auto-start-reverse">
                <polygon points="8 0, 0 2.5, 8 5" fill="#000000" />
              </marker>
            </defs>
            <line x1="0" y1="5" x2="40" y2="5" stroke="#000000" stroke-width="2" marker-start="url(#arrowhead-start)" />
            """))
        // Line heads +x (0°); reversed at the start → 180°. stroke-width 2 → scale(2).
        #expect(out.contains(##"<g transform="translate(0.000,5.000) rotate(180.000) scale(2) translate(-1,-2.5)">"##))
        #expect(!out.contains("marker-start"))
    }

    @Test("A document with no markers or colour functions passes through unchanged")
    func passthrough() {
        let plain = svg(body: ##"<rect fill="#FF0000"/>"##)
        #expect(MermaidSVGFlattener.flatten(plain) == plain)
    }
}
