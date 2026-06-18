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
}
