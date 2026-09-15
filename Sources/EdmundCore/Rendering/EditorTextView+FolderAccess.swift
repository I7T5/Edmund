import AppKit

extension NSAttributedString.Key {
    /// Marks an image token whose file sits in a folder the sandbox hasn't
    /// granted, so a cmd+click offers the folder grant (`FolderAccess`).
    static let editorNeedsFolderAccess = NSAttributedString.Key("EditorNeedsFolderAccess")
}

// MARK: - Folder grants (App Sandbox)
//
// The one UI surface of `FolderAccess`: an open panel preset to the document's
// folder, reached from a cmd+click on a "Folder access needed" image
// placeholder, from a wiki link whose target can't be read, or from
// File ▸ Grant Access to Folder…. No prompt is ever raised mid-render.

extension EditorTextView {

    /// The document's folder when the sandbox needs a grant to read beside it.
    var ungrantedDocumentFolder: URL? {
        guard FolderAccess.isSandboxed,
              let dir = document?.fileURL?.deletingLastPathComponent(),
              !FolderAccess.covers(dir) else { return nil }
        return dir
    }

    /// Whether the click lands on a placeholder that offers the grant.
    func needsFolderAccessHit(at event: NSEvent) -> Bool {
        guard let storage = textStorage, let i = clickCharIndex(at: event) else { return false }
        return storage.attribute(.editorNeedsFolderAccess, at: i, effectiveRange: nil) != nil
    }

    /// File ▸ Grant Access to Folder… (responder chain).
    @objc public func grantFolderAccess(_ sender: Any?) {
        requestFolderAccess()
    }

    /// Asks for the document's folder; on OK stores the grant, restyles so
    /// placeholders become images, then runs `then` (a retried link follow).
    func requestFolderAccess(then: (() -> Void)? = nil) {
        guard let window, let dir = document?.fileURL?.deletingLastPathComponent() else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.directoryURL = dir
        panel.prompt = "Grant Access"
        panel.message = "Allow Edmund to read images and linked notes next to this document."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            FolderAccess.grant(url)
            self?.recomposeAllDirty()
            then?()
        }
    }
}
