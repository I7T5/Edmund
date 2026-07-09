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

    // MARK: - Untitled Window Cleanup
    //
    // Apple's documented single funnel for opening an existing file — the Open
    // panel, Recent Items, and drag-and-drop all call this — so hooking it
    // here catches every "open another file" path in one place.
    override func openDocument(withContentsOf url: URL, display displayDocument: Bool,
                               completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        super.openDocument(withContentsOf: url, display: displayDocument) { document, alreadyOpen, error in
            if let document, error == nil {
                self.closeUntouchedUntitledWindows(keeping: document)
            }
            completionHandler(document, alreadyOpen, error)
        }
    }

    /// Closes any other blank Untitled window the user never typed into —
    /// e.g. the automatic blank document from launch — once a real file opens.
    /// `isDocumentEdited` already tracks this: edits call `updateChangeCount`
    /// (`EditorTextView+EditFlow.swift`), so an untouched Untitled document is
    /// never marked edited.
    private func closeUntouchedUntitledWindows(keeping opened: NSDocument) {
        for case let doc as Document in documents where doc !== opened {
            if doc.fileURL == nil && !doc.isDocumentEdited {
                doc.close()
            }
        }
    }
}
