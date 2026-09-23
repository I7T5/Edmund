import Testing
import AppKit
@testable import EdmundCore

/// Edit ▸ Copy As. Each test writes to its own named pasteboard, never the
/// user's clipboard.
@Suite("Copy As")
@MainActor
struct CopyAsTests {

    private func pasteboard() -> NSPasteboard { NSPasteboard.withUniqueName() }

    @Test("Plain Text puts the stripped text on the clipboard, with no trailing newline")
    func plainText() {
        let pb = pasteboard()
        DocumentExporter.copyPlainText(markdown: "Some **bold** and a [link](https://x.org)", to: pb)
        #expect(pb.string(forType: .string) == "Some bold and a link (https://x.org)")
        #expect(pb.data(forType: .rtf) == nil && pb.data(forType: .html) == nil)   // text only
    }

    @Test("Rich Text carries RTF, HTML and the plain-text form in one item")
    func richText() throws {
        let pb = pasteboard()
        try DocumentExporter.copyRichText(markdown: "- [x] **done**", theme: .default,
                                          callouts: Callout.defaultStyles, to: pb)
        #expect(pb.pasteboardItems?.count == 1)
        let rtf = try #require(pb.data(forType: .rtf))
        let text = try #require(NSAttributedString(rtf: rtf, documentAttributes: nil))
        #expect(text.string.contains("☑ done"))
        #expect(pb.string(forType: .html)?.contains("<strong>done</strong>") == true)
        #expect(pb.string(forType: .string) == "☑ done")
        #expect(pb.data(forType: .rtfd) == nil)   // no pictures, no RTFD
    }

    @Test("Rich Text adds RTFD when the selection has a picture")
    func richTextWithMath() throws {
        let pb = pasteboard()
        try DocumentExporter.copyRichText(markdown: "Energy $E=mc^2$", theme: .default,
                                          callouts: Callout.defaultStyles, to: pb)
        let rtfd = try #require(pb.data(forType: .rtfd))
        let text = try #require(NSAttributedString(rtfd: rtfd, documentAttributes: nil))
        var attachments = 0
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { v, _, _ in
            if v != nil { attachments += 1 }
        }
        #expect(attachments == 1)
    }
}
