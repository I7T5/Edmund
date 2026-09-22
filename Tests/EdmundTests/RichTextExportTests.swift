import Testing
import AppKit
import CryptoKit
@testable import EdmundCore

@Suite("Rich text export")
@MainActor
struct RichTextExportTests {

    private func html(_ md: String) -> String {
        RichTextExport.html(markdown: md, theme: .default, callouts: Callout.defaultStyles,
                            baseURL: nil, options: .default)
    }

    private func rich(_ md: String) throws -> NSAttributedString {
        try RichTextExport.attributedString(fromHTML: html(md))
    }

    @Test("Formatting arrives as real attributes, not markdown syntax")
    func formatting() throws {
        let text = try rich("# Title\n\nSome **bold** text.")
        #expect(text.string.hasPrefix("Title\nSome bold text."))
        let boldAt = (text.string as NSString).range(of: "bold").location
        let font = text.attribute(.font, at: boldAt, effectiveRange: nil) as? NSFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }

    @Test("Tasks keep their state as ☐/☑ on the task's own line")
    func tasks() throws {
        let s = try rich("- [ ] todo\n- [x] done").string
        #expect(s.contains("☐ todo"))
        #expect(s.contains("☑ done"))
    }

    @Test("Ordered lists read 1. 2., in the text and in the list format")
    func orderedListPeriods() throws {
        let text = try rich("1. first\n2. second\n\n- bullet")
        #expect(text.string.contains("\t1.\tfirst"))
        #expect(text.string.contains("\t2.\tsecond"))
        let style = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(style?.textLists.last?.markerFormat.rawValue == "{decimal}.")
        // Both items still share one list, so a word processor numbers them together.
        let second = (text.string as NSString).range(of: "second").location
        let style2 = text.attribute(.paragraphStyle, at: second, effectiveRange: nil) as? NSParagraphStyle
        #expect(style?.textLists.last === style2?.textLists.last)
        // Bullets are left alone.
        #expect(!text.string.contains("•."))
    }

    @Test("App-internal links are unwrapped to their text")
    func internalLinks() throws {
        let text = try rich("See [[Other Note]] and [site](https://x.org).\n\n```\ncode\n```")
        var schemes: [String] = []
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let url = value as? URL { schemes.append(url.scheme ?? "") }
            if let str = value as? String { schemes.append(URL(string: str)?.scheme ?? "") }
        }
        #expect(schemes == ["https"])
        #expect(text.string.contains("Other Note"))
    }

    @Test("Tables stay tables")
    func tables() throws {
        let text = try rich("| A | B |\n| --- | --- |\n| 1 | 2 |")
        var hasTable = false
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let style = value as? NSParagraphStyle,
               style.textBlocks.contains(where: { $0 is NSTextTableBlock }) { hasTable = true }
        }
        #expect(hasTable)
    }

    @Test("Pictures make it RTFD, with the picture inside; none → a plain RTF file")
    func rtfOrRtfd() throws {
        let plain = html("Just text.")
        #expect(!RichTextExport.needsAttachments(plain))
        let rtf = try RichTextExport.fileWrapper(for: RichTextExport.attributedString(fromHTML: plain), rtfd: false)
        #expect(rtf.isRegularFile)
        #expect(String(decoding: rtf.regularFileContents ?? Data(), as: UTF8.self).hasPrefix("{\\rtf1"))

        let withMath = html("Energy $E=mc^2$.")
        #expect(RichTextExport.needsAttachments(withMath))
        let rtfd = try RichTextExport.fileWrapper(for: RichTextExport.attributedString(fromHTML: withMath), rtfd: true)
        #expect(rtfd.isDirectory)
        #expect(rtfd.fileWrappers?.keys.contains("TXT.rtf") == true)
        #expect(rtfd.fileWrappers?.keys.contains { $0.hasSuffix(".png") } == true)
    }

    // MARK: Mermaid (gated on a real payload, like MermaidEditModeTests)

    @Test("A diagram arrives as a picture — the importer would drop its SVG")
    func mermaidPicture() async throws {
        guard let path = ProcessInfo.processInfo.environment["MERMAID_ARCHIVE"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mermaid-rt-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: dir)
            MermaidRenderer.shared.unload()
            MermaidRenderer.shared.isEnabled = false
        }
        try await ExtensionPayloadInstaller(payload: MermaidRelease.payload)
            .installAtomically(archive: data, sha256: sha, into: dir)
        MermaidRenderer.shared.load(dir: dir)
        MermaidRenderer.shared.isEnabled = true

        let page = html("```mermaid\ngraph TD\n  A[Write] --> B[Preview]\n```")
        let body = try #require(page.range(of: "<body>").map { String(page[$0.upperBound...]) })
        #expect(body.contains("class=\"mermaid-diagram\"><img "))
        #expect(!body.contains("<svg"))
        #expect(RichTextExport.needsAttachments(page))
        let text = try RichTextExport.attributedString(fromHTML: page)
        var attachments = 0
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { v, _, _ in
            if v != nil { attachments += 1 }
        }
        #expect(attachments == 1)
    }
}
