import AppKit
import UniformTypeIdentifiers

// MARK: - Dropping image files
//
// Dragging image files in from Finder inserts `![alt text](path)` at the drop
// point, using the same destination logic as Image ▸ Attach File…
// (`imageDestination(for:)`): relative when the file sits under the document's
// own folder, absolute otherwise. The file is referenced where it lies — Edmund
// never copies it — so moving the image later breaks the link.
//
// The hook is `readSelection(from:type:)` rather than a hand-rolled
// `performDragOperation`, because NSTextView's drag destination already tracks
// the pointer with a drop caret and sets the insertion point to the drop
// location *before* calling us. Reimplementing the drag destination would mean
// recomputing the drop index by hand and losing that caret feedback.
//
// The insert runs through `applyFormattingEdit`, the sanctioned mutation path,
// so undo/rawSource/recompose all stay in sync — none of the didChangeText
// bypass hazard that a raw `replaceCharacters` on a drop would carry
// (see EditorTextView+EditFlow).

extension EditorTextView {

    /// Only image files are accepted. The *pasteboard* does the filtering
    /// (`urlReadingContentsConformToTypes`) rather than an extension whitelist
    /// of ours, so anything the system considers an image — including formats
    /// added by a future macOS — comes through, and nothing else does.
    private static let imageURLReadingOptions: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true,
        .urlReadingContentsConformToTypes: [UTType.image.identifier],
    ]

    /// `.fileURL` must come **first**: a Finder drag carries both a file URL and
    /// a plain-string representation of the path, and `readSelection(from:)`
    /// takes the first supported type it finds. Behind `.string` the drop would
    /// paste a bare path instead of an image link.
    ///
    /// This list also drives `paste:`, so ⌘V of an image file copied in Finder
    /// inserts the same Markdown a drop would.
    public override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.fileURL] + super.readablePasteboardTypes
    }

    public override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        [.fileURL] + super.acceptableDragTypes
    }

    public override func readSelection(from pboard: NSPasteboard,
                                       type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .fileURL else { return super.readSelection(from: pboard, type: type) }

        let urls = pboard.readObjects(forClasses: [NSURL.self],
                                      options: Self.imageURLReadingOptions) as? [URL] ?? []
        // Not an image (a dropped .md, .zip, …): decline, so AppKit reports the
        // drop as refused rather than silently swallowing it.
        guard !urls.isEmpty else { return false }

        // An untitled document has no folder to be relative to, so every
        // destination would come out absolute and silently point at the wrong
        // place once the file is saved somewhere else. Save first, then insert.
        if let doc = document, doc.fileURL == nil {
            promptToSaveThenInsert(urls, into: doc)
            return true
        }

        insertImages(at: urls)
        return true
    }

    /// Runs the standard Save sheet, then inserts once the document has a URL.
    ///
    /// Deferred to the next run-loop pass on purpose: this is called from inside
    /// the drag callback, and presenting a sheet before the drag session has
    /// finished unwinding wedges the drag. `RunLoop.perform` rather than
    /// `DispatchQueue.main.async` for the same reason as the bypassed-edit check
    /// — identical timing in the app, but drainable by `RunLoop.main.run(until:)`
    /// in tests.
    private func promptToSaveThenInsert(_ urls: [URL], into doc: NSDocument) {
        pendingDroppedImages = urls
        RunLoop.main.perform { [weak self, weak doc] in
            // The main run loop only ever performs on the main thread; the
            // closure just isn't statically annotated as such.
            MainActor.assumeIsolated {
                guard let self, let doc else { return }
                doc.save(withDelegate: self,
                         didSave: #selector(EditorTextView.document(_:didSave:contextInfo:)),
                         contextInfo: nil)
            }
        }
    }

    /// `save(withDelegate:…)` callback. Cancelled save → drop the pending URLs
    /// and leave the document untouched.
    @objc func document(_ doc: NSDocument, didSave: Bool, contextInfo: UnsafeMutableRawPointer?) {
        let urls = pendingDroppedImages
        pendingDroppedImages = []
        guard didSave, doc.fileURL != nil else { return }
        insertImages(at: urls)
    }
}
