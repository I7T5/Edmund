import Testing
import AppKit
@testable import EdmundCore

@Suite("Styled-content cache invalidation")
@MainActor
struct RenderCacheInvalidationTests {
    private final class TallMathRenderer: MathRenderer {
        let id = "callout-cache-test-\(UUID().uuidString)"
        let isReady = true

        func render(latex: String, displayMode: Bool,
                    pointSize: CGFloat, color: NSColor) -> RenderedMath? {
            RenderedMath(image: NSImage(size: NSSize(width: 50, height: 50)),
                         ascent: 40, descent: 10)
        }
    }

    @Test("A cached callout follows math engine changes in both directions")
    func calloutMathEngine() throws {
        let previous = MathRendering.shared.alternate
        defer { MathRendering.shared.alternate = previous }
        MathRendering.shared.alternate = nil
        let editor = makeEditor()
        let source = "> [!note]\n> $y^3$"
        let position = (source as NSString).range(of: "$y^3$").location
        func overlayHeight() throws -> CGFloat {
            let styled = editor.styleBlock(source)
            let overlay = try #require(styled.attribute(
                .fragmentOverlay, at: position, effectiveRange: nil) as? FragmentOverlay)
            return overlay.bounds.height
        }
        let original = try overlayHeight()
        #expect(original != 50)
        MathRendering.shared.alternate = TallMathRenderer()
        #expect(try overlayHeight() == 50)
        MathRendering.shared.alternate = nil
        #expect(try overlayHeight() == original)
    }

    private func writePNG(_ url: URL, size: NSSize) throws {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        let rep = try #require(NSBitmapImageRep(data: image.tiffRepresentation!))
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }

    private func imageOverlay(in styled: NSAttributedString) -> FragmentOverlay? {
        let pos = (styled.string as NSString).range(of: "![").location
        guard pos != NSNotFound else { return nil }
        return styled.attribute(.fragmentOverlay, at: pos, effectiveRange: nil) as? FragmentOverlay
    }

    @Test("A table image appears after its file becomes available")
    func tableImageLoadState() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("edmund-table-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let source = "| Picture |\n| --- |\n| ![alt](\(url.path)) |"
        let editor = makeEditor()

        let missing = try #require(imageOverlay(in: editor.styleBlock(source)))
        #expect(missing.bounds.width != 24 || missing.bounds.height != 16)

        try writePNG(url, size: NSSize(width: 24, height: 16))
        let loaded = try #require(imageOverlay(in: editor.styleBlock(source)))
        #expect(loaded.bounds.size == NSSize(width: 24, height: 16))
    }

    @Test("The same callout image resolves in each document's folder")
    func calloutDocumentFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edmund-callout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("one", isDirectory: true)
        let second = root.appendingPathComponent("two", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try writePNG(first.appendingPathComponent("pic.png"),
                     size: NSSize(width: 24, height: 16))
        try writePNG(second.appendingPathComponent("pic.png"),
                     size: NSSize(width: 48, height: 32))

        let source = "> [!note]\n> ![alt](pic.png)"
        let editor1 = makeEditor()
        let doc1 = NSDocument()
        doc1.fileURL = first.appendingPathComponent("note.md")
        editor1.document = doc1
        let overlay1 = try #require(imageOverlay(in: editor1.styleBlock(source)))

        let editor2 = makeEditor()
        let doc2 = NSDocument()
        doc2.fileURL = second.appendingPathComponent("note.md")
        editor2.document = doc2
        let overlay2 = try #require(imageOverlay(in: editor2.styleBlock(source)))

        #expect(overlay1.bounds.size == NSSize(width: 24, height: 16))
        #expect(overlay2.bounds.size == NSSize(width: 48, height: 32))
    }
}
