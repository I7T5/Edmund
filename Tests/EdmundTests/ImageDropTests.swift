import Testing
import AppKit
@testable import EdmundCore

/// Drops enter through `performDragOperation(_:)` — the AppKit hook the drag
/// machinery calls — driven by a fake `NSDraggingInfo` against a pasteboard
/// we build ourselves, with the editor hosted in a real window (the drop
/// point converts through window coordinates). What headless tests *cannot*
/// prove is that AppKit routes a real Finder drop into that hook at all;
/// that needs a live cross-application drag.
///
/// Policies (copy into assets vs link, unsaved documents) live in
/// EditorTextView+ImageAttachments and are tested there; this suite covers
/// the wiring and the `.fileURL`-typing plumbing.
@Suite("Image drop")
@MainActor
struct ImageDropTests {

    // MARK: - Fixtures

    /// A real image file on disk.
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
    /// the life of the test (same pattern as ImageAttachmentTests).
    private func editor(inDocumentAt url: URL?) -> (EditorTextView, NSDocument) {
        let e = makeEditor()
        let doc = NSDocument()
        doc.fileURL = url
        e.document = doc
        return (e, doc)
    }

    /// The editor hosted in a window: `performDragOperation` converts the
    /// drag location from window coordinates, which needs a window.
    private func windowedEditor(inDocumentAt url: URL?) -> (NSWindow, EditorTextView, NSDocument) {
        let (e, doc) = editor(inDocumentAt: url)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.contentView = e
        return (window, e, doc)
    }

    private func pasteboard(with urls: [URL]) -> NSPasteboard {
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        return pb
    }

    /// A minimal `NSDraggingInfo` carrying `pasteboard`, dropping at the
    /// view's top-left (the character index it maps to doesn't matter for
    /// wiring — the insertion-point test sets the selection instead).
    @MainActor
    private class FakeDraggingInfo: NSObject, @preconcurrency NSDraggingInfo {
        let draggingPasteboard: NSPasteboard
        init(pasteboard: NSPasteboard) { self.draggingPasteboard = pasteboard }
        var draggingSequenceNumber: Int = 0
        var draggingSource: Any? = nil
        var draggingSourceOperationMask: NSDragOperation = .copy
        var draggingDestinationWindow: NSWindow? = nil
        var draggingLocation: CGPoint = .zero
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination: Bool = false
        var numberOfValidItemsForDrop: Int = 1
        var draggedImage: NSImage? = nil
        var draggedImageLocation: CGPoint = .zero
        var springLoadingHighlight: NSSpringLoadingHighlight = .none
        func slideDraggedImage(to screenPoint: CGPoint) {}
        func resetSpringLoading() {}
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions,
                                    for view: NSView?, classes: [AnyClass],
                                    searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                    using block: @escaping (NSDraggingItem, Int,
                                                            UnsafeMutablePointer<ObjCBool>) -> Void) {}
    }

    // MARK: - Drop wiring

    @Test("Dropping an image file attaches it: copied into assets, relative path inserted")
    func dropAttachesImage() {
        let docDir = makeDocDirectory()
        let otherDir = makeDocDirectory()
        let png = writePNG("cat.png", in: otherDir)
        let (_, e, doc) = windowedEditor(inDocumentAt: docDir.appendingPathComponent("journal.md"))

        let info = FakeDraggingInfo(pasteboard: pasteboard(with: [png]))
        #expect(e.performDragOperation(info))
        #expect(e.rawSource == "![](journal.assets/cat.png)")
        #expect(FileManager.default.fileExists(
            atPath: docDir.appendingPathComponent("journal.assets/cat.png").path))
        _ = doc
    }

    @Test("Dropping several images attaches each")
    func dropAttachesMultipleImages() {
        let docDir = makeDocDirectory()
        let otherDir = makeDocDirectory()
        let cat = writePNG("cat.png", in: otherDir)
        let dog = writePNG("dog.png", in: otherDir)
        let (_, e, doc) = windowedEditor(inDocumentAt: docDir.appendingPathComponent("journal.md"))

        let info = FakeDraggingInfo(pasteboard: pasteboard(with: [cat, dog]))
        #expect(e.performDragOperation(info))
        #expect(e.rawSource == "![](journal.assets/cat.png)\n\n![](journal.assets/dog.png)")
        _ = doc
    }

    /// Mixed drops attach the images; the non-image is filtered out by the
    /// classifier rather than rejecting the whole drop.
    @Test("A mixed drop attaches only the images")
    func mixedDropAttachesOnlyImages() {
        let docDir = makeDocDirectory()
        let png = writePNG("cat.png", in: docDir)
        let txt = docDir.appendingPathComponent("notes.txt")
        try! "hello".write(to: txt, atomically: true, encoding: .utf8)
        let (_, e, doc) = windowedEditor(inDocumentAt: docDir.appendingPathComponent("journal.md"))

        let info = FakeDraggingInfo(pasteboard: pasteboard(with: [txt, png]))
        #expect(e.performDragOperation(info))
        #expect(e.rawSource == "![](journal.assets/cat.png)")
        _ = doc
    }

    @Test("The drop lands at the insertion point the drag location maps to")
    func dropLandsAtTheInsertionPoint() {
        let docDir = makeDocDirectory()
        let png = writePNG("cat.png", in: docDir)
        let (_, e, doc) = windowedEditor(inDocumentAt: docDir.appendingPathComponent("journal.md"))
        e.loadContent("see ")

        // The fake drop point is the window origin — bottom-left in AppKit
        // coordinates — which is nearest the last character: the image lands
        // at the end of the line.
        let info = FakeDraggingInfo(pasteboard: pasteboard(with: [png]))
        #expect(e.performDragOperation(info))
        #expect(e.rawSource == "see ![](journal.assets/cat.png)")
        _ = doc
    }

    /// An untitled document has no folder to be relative to, so the attach
    /// flow refuses (no save hook wired in unit tests). Nothing is inserted.
    @Test("Dropping on an untitled document inserts nothing")
    func untitledDocumentInsertsNothing() {
        let dir = makeDocDirectory()
        let png = writePNG("cat.png", in: dir)
        let (_, e, doc) = windowedEditor(inDocumentAt: nil)

        let info = FakeDraggingInfo(pasteboard: pasteboard(with: [png]))
        #expect(e.performDragOperation(info))
        #expect(e.rawSource == "")
        _ = doc
    }

    /// The attach goes through `applyFormattingEdit`, so storage must agree
    /// with a from-scratch recompose (same check FormattingTests makes for
    /// the menu).
    @Test("Storage matches a full recompose after a drop")
    func storageMatchesOracleAfterDrop() {
        let docDir = makeDocDirectory()
        let png = writePNG("cat.png", in: docDir)
        let (_, e, doc) = windowedEditor(inDocumentAt: docDir.appendingPathComponent("journal.md"))
        e.loadContent("see ")
        e.setSelectedRange(NSRange(location: 4, length: 0))

        let info = FakeDraggingInfo(pasteboard: pasteboard(with: [png]))
        _ = e.performDragOperation(info)
        drainAllStyling(e)
        assertMatchesFullRecomposeOracle(e)
        _ = doc
    }

    // MARK: - Typing plumbing

    /// `.fileURL` has to outrank `.string`, or a Finder drag — which carries
    /// both — would paste a bare path instead of reaching the attach flow.
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

    /// A non-image file must fall through `.fileURL` (declined here) to
    /// `.string`, so AppKit pastes the path as text instead of the drop being
    /// swallowed.
    @Test("readSelection declines fileURL so non-image drops fall through")
    func readSelectionDeclinesFileURL() {
        let dir = makeDocDirectory()
        let txt = dir.appendingPathComponent("notes.txt")
        try! "hello".write(to: txt, atomically: true, encoding: .utf8)
        let (e, doc) = editor(inDocumentAt: dir.appendingPathComponent("journal.md"))

        #expect(e.readSelection(from: pasteboard(with: [txt]), type: .fileURL) == false)
        #expect(e.rawSource == "")
        _ = doc
    }
}
