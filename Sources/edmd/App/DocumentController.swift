import AppKit
import UniformTypeIdentifiers

/// Custom document controller that registers our Document class for markdown files.
///
/// Without an Info.plist (SPM executable), NSDocumentController's default
/// `openDocument:` is broken because it relies on CFBundleDocumentTypes for
/// type validation. We override it to show the Open panel ourselves and
/// create Document instances directly.
class DocumentController: NSDocumentController {

    // MARK: - Type Registration

    override var documentClassNames: [String] {
        ["Document"]
    }

    override var defaultType: String? {
        "net.daringfireball.markdown"
    }

    override func documentClass(forType typeName: String) -> AnyClass? {
        Document.self
    }

    override func typeForContents(of url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        if ext == "md" || ext == "markdown" || ext == "mdown" || ext == "mkd" {
            return "net.daringfireball.markdown"
        }
        return "public.plain-text"
    }

    // MARK: - Open Document (manual implementation)

    /// Completely replaces NSDocumentController's openDocument: because the
    /// default implementation refuses to show the panel without Info.plist
    /// type registrations.
    @MainActor
    override func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        // Allow all files — our read(from:ofType:) handles UTF-8 decoding.
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            self.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error = error {
                    NSAlert(error: error).runModal()
                }
            }
        }
    }

    // MARK: - New Document With Content
    //
    // Seeds a fresh untitled document with `content` and shows it. The standard
    // NSDocument dance (make → set pendingContent → add → windows → mark dirty)
    // reuses `Document.pendingContent`, consumed in `Document.showWindows()`.
    // Shared by the "New Edmund Document" App Intent and the Services provider
    // so both routes create documents identically.
    @MainActor
    @discardableResult
    func newDocument(withContent content: String) -> Document? {
        guard let doc = try? makeUntitledDocument(
            ofType: defaultType ?? "net.daringfireball.markdown") as? Document else { return nil }
        doc.pendingContent = content
        addDocument(doc)
        doc.makeWindowControllers()
        doc.showWindows()
        doc.updateChangeCount(.changeDone)
        return doc
    }

    // MARK: - Untitled Window Cleanup
    //
    // Apple's documented single funnel for opening an existing file — the Open
    // panel, Recent Items, and drag-and-drop all call this — so hooking it
    // here catches every "open another file" path in one place.
    override func openDocument(withContentsOf url: URL, display displayDocument: Bool,
                               completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        super.openDocument(withContentsOf: url, display: displayDocument) { document, alreadyOpen, error in
            if let document, error == nil {
                self.closeLastUntouchedUntitledWindow(keeping: document)
            }
            completionHandler(document, alreadyOpen, error)
        }
    }

    // MARK: - Draft Reopening
    //
    // With autosave-in-place on, AppKit keeps every unsaved *untitled* document as
    // a draft in ~/Library/Autosave Information and reopens it through this method
    // at the next launch. That path is not gated by `NSWindow.isRestorable`, so the
    // clearing in `AppDelegate.applicationShouldTerminate` never reached it: drafts
    // came back at every launch — stacking up as "Untitled", "Untitled 2", … on top
    // of the blank launch document — whatever "Reopen windows from last session"
    // said. Honor that preference here too. Nothing is deleted: the draft files stay
    // in ~/Library/Autosave Information, they are simply not reopened.
    //
    // `urlOrNil == nil` is exactly the draft case; a document that has a file on
    // disk reopens as before.
    override func reopenDocument(for urlOrNil: URL?, withContentsOf contentsURL: URL,
                                 display displayDocument: Bool,
                                 completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        if urlOrNil == nil && !AppSettings.reopenWindows {
            completionHandler(nil, false, nil)
            return
        }
        super.reopenDocument(for: urlOrNil, withContentsOf: contentsURL,
                             display: displayDocument, completionHandler: completionHandler)
    }

    /// Closes the most-recently-opened blank Untitled window the user never
    /// typed into — e.g. the automatic blank document from launch — once a
    /// real file opens. Only the last one, so opening several Untitled
    /// windows on purpose still leaves the earlier ones alone.
    /// `isDocumentEdited` already tracks "untyped": edits call
    /// `updateChangeCount` (`EditorTextView+EditFlow.swift`), so an untouched
    /// Untitled document is never marked edited.
    private func closeLastUntouchedUntitledWindow(keeping opened: NSDocument) {
        let stale = documents.last { doc in
            guard let doc = doc as? Document, doc !== opened else { return false }
            return doc.fileURL == nil && !doc.isDocumentEdited
        }
        stale?.close()
    }
}
