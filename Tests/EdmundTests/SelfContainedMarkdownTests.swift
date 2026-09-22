import Testing
import AppKit
@testable import EdmundCore

/// Tests for SelfContainedMarkdown.inlineLocalImages — the transform behind
/// File ▸ Export Self-contained Markdown. Local images become base64 data
/// URIs; remote/already-inlined/missing images and anything inside code pass
/// through untouched.
struct SelfContainedMarkdownTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EdmundTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func writePNG(_ name: String, into dir: URL) throws -> String {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        let data = rep.representation(using: .png, properties: [:])!
        try data.write(to: dir.appendingPathComponent(name))
        return "data:image/png;base64,\(data.base64EncodedString())"
    }

    private func inline(_ markdown: String, in dir: URL?) -> String {
        SelfContainedMarkdown.inlineLocalImages(markdown: markdown, baseURL: dir)
    }

    @Test func localImageIsInlined() throws {
        let dir = try makeTempDir()
        let uri = try writePNG("a.png", into: dir)
        #expect(inline("![cat](a.png)", in: dir) == "![cat](\(uri))")
    }

    @Test func altAndTitleArePreserved() throws {
        let dir = try makeTempDir()
        let uri = try writePNG("a.png", into: dir)
        #expect(inline("![my alt](a.png \"the title\")", in: dir)
                == "![my alt](\(uri) \"the title\")")
    }

    @Test func imageInSubdirectoryIsInlined() throws {
        let dir = try makeTempDir()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("notes.assets"),
                                                withIntermediateDirectories: true)
        let uri = try writePNG("notes.assets/p.png", into: dir)
        #expect(inline("![](notes.assets/p.png)", in: dir) == "![](\(uri))")
    }

    @Test func percentEncodedPathResolves() throws {
        let dir = try makeTempDir()
        let uri = try writePNG("my cat.png", into: dir)
        #expect(inline("![](my%20cat.png)", in: dir) == "![](\(uri))")
    }

    @Test func remoteAndInlinedSourcesPassThrough() throws {
        let dir = try makeTempDir()
        let md = "![a](https://example.com/x.png)\n\n![b](data:image/png;base64,AAAA)"
        #expect(inline(md, in: dir) == md)
    }

    @Test func missingFilePassesThrough() throws {
        let dir = try makeTempDir()
        let md = "![gone](nope.png)"
        #expect(inline(md, in: dir) == md)
    }

    @Test func fileThatIsNotAnImagePassesThrough() throws {
        let dir = try makeTempDir()
        try Data("not an image".utf8).write(to: dir.appendingPathComponent("fake.png"))
        let md = "![](fake.png)"
        #expect(inline(md, in: dir) == md)
    }

    @Test func fencedCodeBlockIsUntouched() throws {
        let dir = try makeTempDir()
        _ = try writePNG("a.png", into: dir)
        let md = "```\n![cat](a.png)\n```"
        #expect(inline(md, in: dir) == md)
    }

    @Test func inlineCodeIsUntouched() throws {
        let dir = try makeTempDir()
        _ = try writePNG("a.png", into: dir)
        let md = "Use `![cat](a.png)` to embed."
        #expect(inline(md, in: dir) == md)
    }

    @Test func inlineHTMLImgSrcIsInlined() throws {
        let dir = try makeTempDir()
        let uri = try writePNG("a.png", into: dir)
        #expect(inline(#"<img src="a.png" width="40">"#, in: dir)
                == #"<img src="\#(uri)" width="40">"#)
    }

    @Test func remoteHTMLImgSrcPassesThrough() throws {
        let dir = try makeTempDir()
        let md = #"<img src="https://example.com/x.png">"#
        #expect(inline(md, in: dir) == md)
    }

    @Test func obsidianImageEmbedIsInlined() throws {
        let dir = try makeTempDir()
        let uri = try writePNG("a.png", into: dir)
        #expect(inline("![[a.png]]", in: dir) == "![](\(uri))")
    }

    @Test func nonImageEmbedPassesThrough() throws {
        let dir = try makeTempDir()
        let md = "![[note.pdf]]"
        #expect(inline(md, in: dir) == md)
    }

    @Test func embedInsideInlineCodeIsUntouched() throws {
        let dir = try makeTempDir()
        _ = try writePNG("a.png", into: dir)
        let md = "Type `![[a.png]]` to embed."
        #expect(inline(md, in: dir) == md)
    }

    @Test func nilBaseURLReturnsInputUnchanged() {
        let md = "![cat](a.png)"
        #expect(inline(md, in: nil) == md)
    }

    @Test func multipleImagesAllInlined() throws {
        let dir = try makeTempDir()
        let uriA = try writePNG("a.png", into: dir)
        let uriB = try writePNG("b.png", into: dir)
        #expect(inline("![](a.png)\n\ntext\n\n![](b.png)", in: dir)
                == "![](\(uriA))\n\ntext\n\n![](\(uriB))")
    }
}
