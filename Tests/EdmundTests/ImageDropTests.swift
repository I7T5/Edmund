import Testing
import AppKit
@testable import EdmundCore

/// Drops exercise `readSelection(from:type:)` — the real AppKit hook the drag
/// machinery calls — against a pasteboard we build ourselves. What headless
/// tests *cannot* prove is that AppKit routes a Finder drop into that hook at
/// all; that needs a live cross-application drag.
@Suite("Image drop")
@MainActor
struct ImageDropTests {

    // MARK: - Fixtures

    /// A real image file on disk. The pasteboard's
    /// `urlReadingContentsConformToTypes` filter inspects actual file contents,
    /// so these fixtures can't be bare paths.
    private func writePNG(_ name: String, in dir: URL) -> URL {
        let size = NSSize(width: 8, height: 8)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(origin: .zero, size: size).fill()
        img.unlockFocus()
        let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
        let url = dir.appendingPathComponent(name)
        try! rep.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    /// A fresh directory to act as the document's folder, so relative
    /// destinations are exercised against files that really exist.
    private func makeDocDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("md-drop-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `imageDestination` reads the document's directory, and
    /// `EditorTextView.document` is weak — callers must hold the document for
    /// the life of the test (same pattern as FormatAttachImageTests).
    private func editor(inDocumentAt url: URL?) -> (EditorTextView, NSDocument) {
        let e = makeEditor()
        let doc = NSDocument()
        doc.fileURL = url
        e.document = doc
        return (e, doc)
    }

    private func pasteboard(with urls: [URL]) -> NSPasteboard {
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        return pb
    }

    // MARK: - Tests

    @Test("Dropping an image file inserts a link with the alt text selected")
    func dropsSingleImage() {
        let dir = makeDocDirectory()
        let png = writePNG("cat.png", in: dir)
        let (e, doc) = editor(inDocumentAt: dir.appendingPathComponent("journal.md"))

        #expect(e.readSelection(from: pasteboard(with: [png]), type: .fileURL))
        #expect(e.rawSource == "![alt text](cat.png)")
        #expect(e.selectedRange() == NSRange(location: 2, length: 8))
        _ = doc
    }

    @Test("An image outside the document's folder keeps an absolute path")
    func dropOutsideDocumentDirectoryIsAbsolute() {
        let docDir = makeDocDirectory()
        let otherDir = makeDocDirectory()
        let png = writePNG("cat.png", in: otherDir)
        let (e, doc) = editor(inDocumentAt: docDir.appendingPathComponent("journal.md"))

        #expect(e.readSelection(from: pasteboard(with: [png]), type: .fileURL))
        #expect(e.rawSource == "![alt text](\(png.standardizedFileURL.path))")
        _ = doc
    }

    @Test("Dropping several images inserts one block each")
    func dropsMultipleImages() {
        let dir = makeDocDirectory()
        let cat = writePNG("cat.png", in: dir)
        let dog = writePNG("dog.png", in: dir)
        let (e, doc) = editor(inDocumentAt: dir.appendingPathComponent("journal.md"))

        #expect(e.readSelection(from: pasteboard(with: [cat, dog]), type: .fileURL))
        #expect(e.rawSource == "![alt text](cat.png)\n\n![alt text](dog.png)")
        _ = doc
    }

    @Test("Dropping a non-image file is declined and changes nothing")
    func declinesNonImageFile() {
        let dir = makeDocDirectory()
        let txt = dir.appendingPathComponent("notes.txt")
        try! "hello".write(to: txt, atomically: true, encoding: .utf8)
        let (e, doc) = editor(inDocumentAt: dir.appendingPathComponent("journal.md"))

        #expect(e.readSelection(from: pasteboard(with: [txt]), type: .fileURL) == false)
        #expect(e.rawSource == "")
        _ = doc
    }

    /// Mixed drops still insert the images; the non-image is filtered out by the
    /// pasteboard's content-type filter rather than rejecting the whole drop.
    @Test("A mixed drop inserts only the images")
    func mixedDropInsertsOnlyImages() {
        let dir = makeDocDirectory()
        let png = writePNG("cat.png", in: dir)
        let txt = dir.appendingPathComponent("notes.txt")
        try! "hello".write(to: txt, atomically: true, encoding: .utf8)
        let (e, doc) = editor(inDocumentAt: dir.appendingPathComponent("journal.md"))

        #expect(e.readSelection(from: pasteboard(with: [txt, png]), type: .fileURL))
        #expect(e.rawSource == "![alt text](cat.png)")
        _ = doc
    }

    @Test("The drop lands at the insertion point AppKit set")
    func dropsAtTheInsertionPoint() {
        let dir = makeDocDirectory()
        let png = writePNG("cat.png", in: dir)
        let (e, doc) = editor(inDocumentAt: dir.appendingPathComponent("journal.md"))
        e.loadContent("see ")
        e.setSelectedRange(NSRange(location: 4, length: 0))

        #expect(e.readSelection(from: pasteboard(with: [png]), type: .fileURL))
        #expect(e.rawSource == "see ![alt text](cat.png)")
        _ = doc
    }

    /// An untitled document has no folder to be relative to, so the drop waits
    /// for a Save. Nothing is inserted in the meantime.
    @Test("Dropping on an untitled document inserts nothing until it is saved")
    func untitledDocumentDefersTheInsert() {
        let dir = makeDocDirectory()
        let png = writePNG("cat.png", in: dir)
        let (e, doc) = editor(inDocumentAt: nil)

        #expect(e.readSelection(from: pasteboard(with: [png]), type: .fileURL))
        #expect(e.rawSource == "")
        #expect(e.pendingDroppedImages.count == 1)
        _ = doc
    }

    /// The deferred save prompt must not run a modal Save panel when there is no
    /// window to sheet onto. It used to: `save(withDelegate:)` falls back to an
    /// *application-modal* panel when `windowForSheet` is nil, and that modal
    /// loop never returns without a window server — one drop test froze every
    /// `@MainActor` test in the suite and CI was cancelled 18 minutes later.
    /// Driven directly rather than by spinning the main run loop: a nested run
    /// loop inside a parallel `@MainActor` test reenters the other
    /// run-loop-driven suites and SIGSEGV'd the whole test process on macOS 14
    /// CI (clean on macOS 15 locally).
    @Test("A deferred save prompt with no window gives up instead of going modal")
    func untitledDocumentWithNoWindowDoesNotBlock() {
        let dir = makeDocDirectory()
        let png = writePNG("cat.png", in: dir)
        let (e, doc) = editor(inDocumentAt: nil)
        _ = e.readSelection(from: pasteboard(with: [png]), type: .fileURL)

        #expect(doc.windowForSheet == nil)
        // Reaching the assertions at all is the check — an app-modal Save panel
        // here would hang forever rather than fail.
        e.presentSavePrompt(for: doc)

        #expect(e.pendingDroppedImages.isEmpty)
        #expect(e.rawSource == "")
        _ = doc
    }

    /// A cancelled Save drops the pending images and leaves the document alone.
    @Test("Cancelling the save discards the pending drop")
    func cancelledSaveDiscardsTheDrop() {
        let dir = makeDocDirectory()
        let png = writePNG("cat.png", in: dir)
        let (e, doc) = editor(inDocumentAt: nil)
        _ = e.readSelection(from: pasteboard(with: [png]), type: .fileURL)

        e.document(doc, didSave: false, contextInfo: nil)
        #expect(e.rawSource == "")
        #expect(e.pendingDroppedImages.isEmpty)
        _ = doc
    }

    /// After a save the document has a folder, so the pending drop inserts —
    /// relative to that folder.
    @Test("Saving completes the pending drop")
    func saveCompletesThePendingDrop() {
        let dir = makeDocDirectory()
        let png = writePNG("cat.png", in: dir)
        let (e, doc) = editor(inDocumentAt: nil)
        _ = e.readSelection(from: pasteboard(with: [png]), type: .fileURL)

        doc.fileURL = dir.appendingPathComponent("journal.md")
        e.document(doc, didSave: true, contextInfo: nil)
        #expect(e.rawSource == "![alt text](cat.png)")
        #expect(e.pendingDroppedImages.isEmpty)
        _ = doc
    }

    /// The drop goes through `applyFormattingEdit`, so storage must agree with a
    /// from-scratch recompose (same check FormattingTests makes for the menu).
    @Test("Storage matches a full recompose after a drop")
    func storageMatchesOracleAfterDrop() {
        let dir = makeDocDirectory()
        let png = writePNG("cat.png", in: dir)
        let (e, doc) = editor(inDocumentAt: dir.appendingPathComponent("journal.md"))
        e.loadContent("see ")
        e.setSelectedRange(NSRange(location: 4, length: 0))

        _ = e.readSelection(from: pasteboard(with: [png]), type: .fileURL)
        drainAllStyling(e)
        assertMatchesFullRecomposeOracle(e)
        _ = doc
    }

    /// `.fileURL` has to outrank `.string`, or a Finder drag — which carries
    /// both — would paste a bare path instead of an image link.
    @Test("fileURL outranks string in the readable types")
    func fileURLIsPreferredOverString() {
        let e = makeEditor()
        let types = e.readablePasteboardTypes
        #expect(types.first == .fileURL)
        if let stringIndex = types.firstIndex(of: .string) {
            #expect(types.firstIndex(of: .fileURL)! < stringIndex)
        }
    }

    @Test("The view accepts file drags")
    func registersFileURLDragType() {
        let e = makeEditor()
        #expect(e.acceptableDragTypes.contains(.fileURL))
        #expect(e.registeredDraggedTypes.contains(.fileURL))
    }

    /// AppKit re-registers the view's dragged types whenever `isEditable`
    /// flips, which the `viewMode` setter does on every switch to and from Read
    /// mode. It rebuilds them from `acceptableDragTypes`, so the file type has
    /// to survive the round trip — otherwise dropping would work only until the
    /// first mode switch.
    @Test("File drags still register after a Read-mode round trip")
    func dragTypeSurvivesViewModeSwitch() {
        let e = makeEditor()
        e.viewMode = .reading
        e.viewMode = .edit
        #expect(e.registeredDraggedTypes.contains(.fileURL))
    }
}
