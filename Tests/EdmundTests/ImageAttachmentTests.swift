import Testing
import AppKit
@testable import EdmundCore

/// Tests for paste/drag image attachment (EditorTextView+ImageAttachments):
/// assets-folder naming, copy/link policies, timestamped pasted-image names,
/// and the markdown insertion itself. Disk work happens in per-test temp dirs.
@MainActor
struct ImageAttachmentTests {

    // MARK: - Helpers

    /// An editor whose document lives at `dir/notes.md` (the file need not
    /// exist on disk — only the URL anchors the assets folder).
    private func editorIn(dir: URL, content: String = "") -> (EditorTextView, NSDocument) {
        let e = makeEditor()
        if !content.isEmpty { e.loadContent(content) }
        let doc = NSDocument()
        doc.fileURL = dir.appendingPathComponent("notes.md")
        e.document = doc
        return (e, doc)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EdmundTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func tinyPNG() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    @discardableResult
    private func writeFile(_ name: String, into dir: URL, data: Data? = nil) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try (data ?? Data("x".utf8)).write(to: url)
        return url
    }

    // MARK: - Assets folder

    @Test func assetsFolderIsPerDocument() throws {
        let dir = try makeTempDir()
        let (e, _) = editorIn(dir: dir)
        #expect(e.assetsDirectoryURL()?.lastPathComponent == "notes.assets")
        #expect(e.assetsDirectoryURL()?.deletingLastPathComponent() == dir)
    }

    @Test func assetsFolderNilWhenUnsaved() {
        let e = makeEditor()
        e.document = NSDocument()   // no fileURL
        #expect(e.assetsDirectoryURL() == nil)
    }

    @Test func copyIntoAssetsCopiesAndKeepsName() throws {
        let dir = try makeTempDir()
        let other = try makeTempDir()
        let src = try writeFile("pic.png", into: other)
        let (e, _) = editorIn(dir: dir)
        let copied = try #require(e.copyIntoAssets(src))
        #expect(copied.lastPathComponent == "pic.png")
        #expect(copied.deletingLastPathComponent().lastPathComponent == "notes.assets")
        #expect(FileManager.default.fileExists(atPath: copied.path))
        // Original stays put (copy, not move).
        #expect(FileManager.default.fileExists(atPath: src.path))
    }

    @Test func copyIntoAssetsDeduplicatesNames() throws {
        let dir = try makeTempDir()
        let src = try writeFile("pic.png", into: dir)
        let (e, _) = editorIn(dir: dir)
        let first = try #require(e.copyIntoAssets(src))
        let second = try #require(e.copyIntoAssets(src))
        #expect(first.lastPathComponent == "pic.png")
        #expect(second.lastPathComponent == "pic-2.png")
    }

    @Test func fileAlreadyInAssetsIsNotCopiedAgain() throws {
        let dir = try makeTempDir()
        let (e, _) = editorIn(dir: dir)
        let assets = try #require(e.assetsDirectoryURL())
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let inside = try writeFile("pic.png", into: assets)
        #expect(e.copyIntoAssets(inside) == inside)
    }

    @Test func pastedImageNameIsTimestampedAndURLSafe() {
        let name = EditorTextView.pastedImageBaseName()
        #expect(name.range(of: #"^pasted-\d{8}-\d{6}$"#, options: .regularExpression) != nil)
    }

    // MARK: - Attaching files

    @Test func attachCopiesFileAndInsertsRelativePath() throws {
        let dir = try makeTempDir()
        let other = try makeTempDir()
        let src = try writeFile("cat.png", into: other, data: tinyPNG())
        let (e, _) = editorIn(dir: dir, content: "hello")

        e.setSelectedRange(NSRange(location: 5, length: 0))
        e.attachImageFiles([src], copy: true, at: nil)

        #expect(e.rawSource == "hello![](notes.assets/cat.png)")
        let assets = try #require(e.assetsDirectoryURL())
        #expect(FileManager.default.fileExists(atPath: assets.appendingPathComponent("cat.png").path))
        // Caret sits in the alt-text slot (2 past the insertion point).
        #expect(e.selectedRange() == NSRange(location: 5 + 2, length: 0))
    }

    @Test func attachLinkOnlyReferencesWithoutCopying() throws {
        let dir = try makeTempDir()
        let other = try makeTempDir()
        let src = try writeFile("cat.png", into: other, data: tinyPNG())
        let (e, _) = editorIn(dir: dir)

        e.attachImageFiles([src], copy: false, at: nil)

        // Outside the document's directory → absolute reference; nothing copied.
        #expect(e.rawSource == "![](\(src.path))")
        let assets = try #require(e.assetsDirectoryURL())
        #expect(!FileManager.default.fileExists(atPath: assets.path))
    }

    @Test func attachLinkOnlyInsideDocDirStaysRelative() throws {
        let dir = try makeTempDir()
        let src = try writeFile("cat.png", into: dir, data: tinyPNG())
        let (e, _) = editorIn(dir: dir)

        e.attachImageFiles([src], copy: false, at: nil)
        #expect(e.rawSource == "![](cat.png)")
    }

    @Test func attachMultipleImagesSeparatesWithBlankLine() throws {
        let dir = try makeTempDir()
        let a = try writeFile("a.png", into: dir, data: tinyPNG())
        let b = try writeFile("b.png", into: dir, data: tinyPNG())
        let (e, _) = editorIn(dir: dir)

        e.attachImageFiles([a, b], copy: true, at: nil)
        #expect(e.rawSource == "![](notes.assets/a.png)\n\n![](notes.assets/b.png)")
        // Multi-image: caret goes to the end, not an alt slot.
        #expect(e.selectedRange().location == (e.rawSource as NSString).length)
    }

    @Test func attachPasteReplacesSelection() throws {
        let dir = try makeTempDir()
        let src = try writeFile("cat.png", into: dir, data: tinyPNG())
        let (e, _) = editorIn(dir: dir, content: "before")

        e.setSelectedRange(NSRange(location: 0, length: 6))
        e.attachImageFiles([src], copy: true, at: nil)
        #expect(e.rawSource == "![](notes.assets/cat.png)")
    }

    // MARK: - Attaching pasted data

    @Test func attachImageDataWritesTimestampedPNG() throws {
        let dir = try makeTempDir()
        let (e, _) = editorIn(dir: dir)

        e.attachImageData(tinyPNG(), at: nil)

        let assets = try #require(e.assetsDirectoryURL())
        let files = try FileManager.default.contentsOfDirectory(atPath: assets.path)
        #expect(files.count == 1)
        #expect(files[0].range(of: #"^pasted-\d{8}-\d{6}\.png$"#,
                               options: .regularExpression) != nil)
        #expect(e.rawSource == "![](notes.assets/\(files[0]))")
    }

    // MARK: - Unsaved document

    @Test func attachWithoutFileURLAndNoHookIsRefused() throws {
        let dir = try makeTempDir()
        let src = try writeFile("cat.png", into: dir, data: tinyPNG())
        let e = makeEditor()
        e.document = NSDocument()   // unsaved, no save hook (unit-test setup)

        e.attachImageFilesViaPasteboardForTest(src)
        #expect(e.rawSource.isEmpty)
        #expect(e.assetsDirectoryURL() == nil)
    }

    @Test func unsavedDocumentRunsSaveHookThenAttaches() throws {
        let dir = try makeTempDir()
        let src = try writeFile("cat.png", into: dir, data: tinyPNG())
        let e = makeEditor()
        let doc = NSDocument()   // unsaved…
        e.document = doc
        var hookRan = false
        e.requestSaveForAttachment = { completion in
            hookRan = true
            doc.fileURL = dir.appendingPathComponent("notes.md")   // …until "saved"
            completion(true)
        }

        e.attachImageFilesViaPasteboardForTest(src)
        #expect(hookRan)
        #expect(e.rawSource == "![](notes.assets/cat.png)")
    }

    @Test func cancelledSaveAbortsAttach() throws {
        let dir = try makeTempDir()
        let src = try writeFile("cat.png", into: dir, data: tinyPNG())
        let e = makeEditor()
        e.document = NSDocument()
        e.requestSaveForAttachment = { completion in completion(false) }

        e.attachImageFilesViaPasteboardForTest(src)
        #expect(e.rawSource.isEmpty)
    }

    // MARK: - Pasteboard classification

    @Test func classifiesImageFileURLs() throws {
        let dir = try makeTempDir()
        let png = try writeFile("a.png", into: dir)
        let txt = try writeFile("b.txt", into: dir)
        let pb = NSPasteboard(name: NSPasteboard.Name("EdmundTests.\(UUID().uuidString)"))
        pb.writeObjects([png as NSURL, txt as NSURL])
        guard case .files(let urls)? = EditorTextView.imageContentKind(of: pb) else {
            Issue.record("expected .files"); return
        }
        #expect(urls == [png])   // non-image files filtered out
    }

    @Test func classifiesPNGData() {
        let pb = NSPasteboard(name: NSPasteboard.Name("EdmundTests.\(UUID().uuidString)"))
        pb.setData(tinyPNG(), forType: .png)
        guard case .data? = EditorTextView.imageContentKind(of: pb) else {
            Issue.record("expected .data"); return
        }
    }

    @Test func classifiesRemoteImageURL() {
        let pb = NSPasteboard(name: NSPasteboard.Name("EdmundTests.\(UUID().uuidString)"))
        pb.writeObjects([NSURL(string: "https://example.com/x.png")!])
        guard case .remoteURL(let url)? = EditorTextView.imageContentKind(of: pb) else {
            Issue.record("expected .remoteURL"); return
        }
        #expect(url.absoluteString == "https://example.com/x.png")
    }

    @Test func plainTextAndNonImageFilesAreNotImageContent() throws {
        let dir = try makeTempDir()
        let txt = try writeFile("b.txt", into: dir)
        let pbFiles = NSPasteboard(name: NSPasteboard.Name("EdmundTests.\(UUID().uuidString)"))
        pbFiles.writeObjects([txt as NSURL])
        #expect(EditorTextView.imageContentKind(of: pbFiles) == nil)

        let pbString = NSPasteboard(name: NSPasteboard.Name("EdmundTests.\(UUID().uuidString)"))
        pbString.setString("hello", forType: .string)
        #expect(EditorTextView.imageContentKind(of: pbString) == nil)

        // A web URL that doesn't point at an image isn't treated as one.
        let pbPage = NSPasteboard(name: NSPasteboard.Name("EdmundTests.\(UUID().uuidString)"))
        pbPage.writeObjects([NSURL(string: "https://example.com/page")!])
        #expect(EditorTextView.imageContentKind(of: pbPage) == nil)
    }

    @Test func remoteURLInsertsWithoutSaving() throws {
        let pb = NSPasteboard(name: NSPasteboard.Name("EdmundTests.\(UUID().uuidString)"))
        pb.writeObjects([NSURL(string: "https://example.com/x.png")!])
        let e = makeEditor()
        e.document = NSDocument()   // unsaved — remote refs need no assets folder
        #expect(e.handleImagePasteboard(pb, at: nil, linkOnly: false))
        #expect(e.rawSource == "![](https://example.com/x.png)")
    }

    // MARK: - Return inside an image token

    @Test func returnInsideImageTokenBreaksAfterIt() {
        let e = makeEditor()
        e.loadContent("before ![](pic.png) after")
        // Caret inside the path — a plain newline here would split the token.
        e.setSelectedRange(NSRange(location: 15, length: 0))
        e.insertNewline(nil)
        #expect(e.rawSource == "before ![](pic.png)\n after")
        // Caret lands on the new line, past its leading space (the editor's
        // own newline handling skips leading whitespace).
        #expect(e.selectedRange().location == 20)
    }

    @Test func returnInsideFreshPasteTokenBreaksAfterIt() {
        // The paste flow parks the caret in the alt-text slot; typing a caption
        // and hitting Return must not break the path.
        let e = makeEditor()
        e.loadContent("![](pic.png)")
        e.setSelectedRange(NSRange(location: 2, length: 0))
        e.insertNewline(nil)
        #expect(e.rawSource == "![](pic.png)\n")
    }

    @Test func returnAtImageTokenStartBreaksBeforeIt() {
        let e = makeEditor()
        e.loadContent("![](pic.png)")
        e.setSelectedRange(NSRange(location: 0, length: 0))
        e.insertNewline(nil)
        #expect(e.rawSource == "\n![](pic.png)")
    }

    @Test func returnOutsideImageTokenIsUnaffected() {
        let e = makeEditor()
        e.loadContent("one\ntwo")
        e.setSelectedRange(NSRange(location: 3, length: 0))
        e.insertNewline(nil)
        #expect(e.rawSource == "one\n\ntwo")
    }

    // MARK: - paste(_:) wiring

    /// ⌘V itself (not the helper): an image on the general pasteboard
    /// attaches; text falls through to the normal paste untouched.
    @Test func pasteOverrideAttachesImageAndPassesTextThrough() throws {
        let dir = try makeTempDir()
        let src = try writeFile("cat.png", into: dir, data: tinyPNG())
        let (e, _) = editorIn(dir: dir)
        let general = NSPasteboard.general
        let savedTypes = general.types ?? []
        defer {
            general.clearContents()
            if !savedTypes.isEmpty { general.declareTypes(savedTypes, owner: nil) }
        }

        general.clearContents()
        general.writeObjects([src as NSURL])
        e.paste(nil)
        #expect(e.rawSource == "![](notes.assets/cat.png)")

        general.clearContents()
        general.setString("plain text", forType: .string)
        e.setSelectedRange(NSRange(location: e.rawSource.utf16.count, length: 0))
        e.paste(nil)
        #expect(e.rawSource == "![](notes.assets/cat.png)plain text")
    }

    @Test func dataURIDecodesAndCaches() {
        let e = makeEditor()
        let uri = "data:image/png;base64,\(tinyPNG().base64EncodedString())"
        guard case .image = e.imageDisplay(destination: uri) else {
            Issue.record("expected a real PNG data URI to decode"); return
        }
        guard case .image = e.imageDisplay(destination: uri) else {
            Issue.record("expected the cached decode on second call"); return
        }
        // A non-base64 / undecodable payload reports Not an image, not Not found.
        guard case .blocked(let failure) = e.imageDisplay(destination: "data:text/plain;base64,aGVsbG8=") else {
            Issue.record("expected undecodable data URI to be blocked"); return
        }
        #expect(failure == .notAnImage)
    }
}

extension EditorTextView {
    /// Test seam: route a single file through the same pasteboard-handling path
    /// (save-first flow included) without fabricating an NSPasteboard.
    fileprivate func attachImageFilesViaPasteboardForTest(_ url: URL) {
        let pb = NSPasteboard(name: NSPasteboard.Name("EdmundTests.\(UUID().uuidString)"))
        pb.writeObjects([url as NSURL])
        #expect(handleImagePasteboard(pb, at: nil, linkOnly: false))
    }
}
