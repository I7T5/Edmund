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

    @Test("Missing local image shows a blocked-image placeholder overlay, not just alt text")
    func fallbackShowsPlaceholder() {
        let editor = makeEditor()
        let styled = editor.styleBlock("![alt](/no/such/file.png)", cursorPosition: nil)
        #expect(styled.attribute(.fragmentOverlay, at: 0, effectiveRange: nil) != nil)
        guard case .blocked(.notFound) = editor.imageDisplay(destination: "/no/such/file.png") else {
            Issue.record("expected .blocked(.notFound)"); return
        }
    }

    @Test("A path that resolves but isn't image data is classified as 'not an image'")
    func notAnImage() {
        let editor = makeEditor()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("md-not-image-\(UUID().uuidString).png")
        try! Data("not a png".utf8).write(to: url)
        guard case .blocked(.notAnImage) = editor.imageDisplay(destination: url.path) else {
            Issue.record("expected .blocked(.notAnImage)"); return
        }
    }

    @Test("Plain-http image always shows the placeholder, even with remote images allowed")
    func httpImageAlwaysBlocked() {
        let editor = makeEditor()
        editor.allowRemoteImages = true
        let styled = editor.styleBlock("![alt](http://example.com/x.png)", cursorPosition: nil)
        #expect(styled.attribute(.fragmentOverlay, at: 0, effectiveRange: nil) != nil)
        guard case .blocked(.httpUnsupported) = editor.imageDisplay(destination: "http://example.com/x.png") else {
            Issue.record("expected .blocked(.httpUnsupported)"); return
        }
    }

    @Test("Https image shows the placeholder while remote images are disallowed")
    func httpsImageBlockedByDefault() {
        let editor = makeEditor()
        editor.allowRemoteImages = false
        let styled = editor.styleBlock("![alt](https://example.com/x.png)", cursorPosition: nil)
        #expect(styled.attribute(.fragmentOverlay, at: 0, effectiveRange: nil) != nil)
        guard case .blocked(.blockedBySetting) = editor.imageDisplay(destination: "https://example.com/x.png") else {
            Issue.record("expected .blocked(.blockedBySetting)"); return
        }
    }

    @Test("Https image is pending (no placeholder yet) while the fetch is in flight")
    func httpsImagePendingWhileFetching() {
        let editor = makeEditor()
        editor.allowRemoteImages = true
        // `.invalid` is RFC 2606-reserved (never resolves) — the request
        // fails async, off the assertion below; only the synchronous
        // first-call return value (.pending, before any response) matters.
        let dest = "https://example.invalid/pending-\(UUID().uuidString).png"
        guard case .pending = editor.imageDisplay(destination: dest) else {
            Issue.record("expected .pending"); return
        }
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
