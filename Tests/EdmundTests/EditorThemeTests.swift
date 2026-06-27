import Testing
import AppKit
@testable import EdmundCore

@Suite("EditorTheme — Math colors")
struct EditorThemeMathColorTests {

    @Test("Default math colors are red (operators) and orange (numbers)")
    @MainActor func defaults() {
        let t = EditorTheme.default
        #expect(t.mathOperatorHex == "#D70015")
        #expect(t.mathNumberHex == "#C77800")
        #expect(t.mathOperatorColor == NSColor(hex: "#D70015"))
        #expect(t.mathNumberColor == NSColor(hex: "#C77800"))
    }

    @Test("Custom math hex resolves to the matching color")
    @MainActor func customHex() {
        let t = EditorTheme(fontName: "Helvetica", fontSize: 14,
                            linkBlueHex: "#000000", codeHex: "#000000",
                            lineSpacing: 0, paragraphSpacingBefore: 0,
                            mathOperatorHex: "#112233", mathNumberHex: "#445566")
        #expect(t.mathOperatorColor == NSColor(hex: "#112233"))
        #expect(t.mathNumberColor == NSColor(hex: "#445566"))
    }

    @Test("An invalid hex falls back to a system color, not a crash")
    @MainActor func invalidHexFallback() {
        let t = EditorTheme(fontName: "Helvetica", fontSize: 14,
                            linkBlueHex: "#000000", codeHex: "#000000",
                            lineSpacing: 0, paragraphSpacingBefore: 0,
                            mathOperatorHex: "nonsense", mathNumberHex: "")
        #expect(t.mathOperatorColor == NSColor.systemRed)
        #expect(t.mathNumberColor == NSColor.systemOrange)
    }
}
