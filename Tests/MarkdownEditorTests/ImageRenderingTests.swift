import Testing
import AppKit
@testable import MarkdownEditorCore

@Suite("Image rendering")
@MainActor
struct ImageRenderingTests {

    /// Writes a tiny solid PNG to a temp file and returns its absolute path
    /// (absolute so resolution doesn't need a document directory).
    private func tempPNGPath() -> String {
        let size = NSSize(width: 24, height: 16)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(origin: .zero, size: size).fill()
        img.unlockFocus()
        let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
        let data = rep.representation(using: .png, properties: [:])!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("md-img-test-\(UUID().uuidString).png")
        try! data.write(to: url)
        return url.path
    }

    @Test("Image syntax parses to an image span carrying the destination")
    func parsesImage() {
        let dests = SyntaxHighlighter.parse("![alt](pic.png)").compactMap { s -> String? in
            if case .image(let d) = s.kind { return d }; return nil
        }
        #expect(dests == ["pic.png"])
    }

    @Test("Rendered image draws an overlay and hides the raw markdown")
    func rendersOverlay() {
        let editor = makeEditor()
        let styled = editor.styleBlock("![alt](\(tempPNGPath()))", cursorPosition: nil)
        // Overlay anchored on the leading `!`.
        let overlay = styled.attribute(.fragmentOverlay, at: 0, effectiveRange: nil) as? FragmentOverlay
        #expect(overlay != nil)
        // The rest of the markdown is hidden (near-zero font).
        let f = styled.attribute(.font, at: 5, effectiveRange: nil) as? NSFont
        #expect((f?.pointSize ?? 99) < 1.0)
    }

    @Test("Active image shows the raw markdown (no overlay)")
    func activeShowsRaw() {
        let editor = makeEditor()
        let styled = editor.styleBlock("![alt](\(tempPNGPath()))", cursorPosition: 3)
        #expect(styled.attribute(.fragmentOverlay, at: 0, effectiveRange: nil) == nil)
    }

    @Test("Unloadable image falls back to alt text (no overlay)")
    func fallbackNoOverlay() {
        let editor = makeEditor()
        let styled = editor.styleBlock("![alt](/no/such/file.png)", cursorPosition: nil)
        #expect(styled.attribute(.fragmentOverlay, at: 0, effectiveRange: nil) == nil)
    }
}
