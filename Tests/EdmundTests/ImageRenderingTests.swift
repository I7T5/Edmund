import Testing
import AppKit
@testable import EdmundCore

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

    @Test("Plain-http image never overlays, even with remote images allowed")
    func httpImageNeverOverlays() {
        let editor = makeEditor()
        editor.allowRemoteImages = true
        let styled = editor.styleBlock("![alt](http://example.com/x.png)", cursorPosition: nil)
        #expect(styled.attribute(.fragmentOverlay, at: 0, effectiveRange: nil) == nil)
    }

    @Test("Https image doesn't overlay while remote images are disallowed")
    func httpsImageBlockedByDefault() {
        let editor = makeEditor()
        editor.allowRemoteImages = false
        let styled = editor.styleBlock("![alt](https://example.com/x.png)", cursorPosition: nil)
        #expect(styled.attribute(.fragmentOverlay, at: 0, effectiveRange: nil) == nil)
    }

    @Test("Narrowing the max-content-width column shrinks an already-rendered image")
    func shrinksOnColumnNarrow() {
        let editor = EditorTextView.makeTextKit2(
            frame: NSRect(x: 0, y: 0, width: 800, height: 300),
            containerSize: NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude))
        let suite = "EdmundTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        editor.themeDefaults = defaults
        editor.theme = .load(from: defaults)

        let content = "![alt](\(tempPNGPath()))\n\nsecond paragraph" // image is 24x16, well under 800pt
        editor.loadContent(content)
        // `loadContent` puts the cursor at offset 0, inside the image block,
        // which renders raw markdown (no overlay) while active. Move the
        // cursor to the second block so the image renders as an overlay.
        editor.recomposeIncremental(cursorInRaw: content.count)
        let before = editor.textStorage?.attribute(.fragmentOverlay, at: 0, effectiveRange: nil) as? FragmentOverlay
        #expect(before?.bounds.width == 24)

        // Cap the column narrower than the image's natural width.
        editor.maxContentWidthPoints = 22

        let after = editor.textStorage?.attribute(.fragmentOverlay, at: 0, effectiveRange: nil) as? FragmentOverlay
        #expect((after?.bounds.width ?? 9999) <= editor.availableContentWidth + 0.01)
        #expect(after!.bounds.width < before!.bounds.width)
        // Aspect ratio preserved (24x16 -> half width -> half height).
        #expect(abs(after!.bounds.height / after!.bounds.width - 16.0 / 24.0) < 0.01)
    }
}
