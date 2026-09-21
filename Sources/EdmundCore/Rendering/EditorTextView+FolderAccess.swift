import AppKit

extension NSAttributedString.Key {
    /// Marks an image token whose folder the sandbox hasn't granted, so a
    /// cmd+click re-offers the grant (`FolderAccess`).
    static let editorNeedsFolderAccess = NSAttributedString.Key("EditorNeedsFolderAccess")
}

// MARK: - Folder grants (App Sandbox)
//
// The one UI surface of `FolderAccess`: an open panel preset to the document's
// folder. Raised automatically, once per folder per launch, when a render
// meets a sibling image it can't read; again from a wiki link whose target
// can't be read; and on cmd+click of a placeholder (the retry after Cancel).

extension EditorTextView {

    /// Folders already prompted this launch — Cancel means "not now", not
    /// "ask again on every restyle".
    // ponytail: main-thread only, same as the store.
    nonisolated(unsafe) private static var promptedFolders = Set<String>()

    /// The document's folder when the sandbox needs a grant to read beside it.
    var ungrantedDocumentFolder: URL? {
        guard FolderAccess.isSandboxed,
              let dir = document?.fileURL?.deletingLastPathComponent(),
              !FolderAccess.covers(dir) else { return nil }
        return dir
    }

    func needsFolderAccessHit(at event: NSEvent) -> Bool {
        guard let storage = textStorage, let i = clickCharIndex(at: event) else { return false }
        return storage.attribute(.editorNeedsFolderAccess, at: i, effectiveRange: nil) != nil
    }

    /// Called from styling: defers the panel off the render path and out of
    /// the initial layout, when the window may not exist yet.
    func promptForFolderAccessOnce() {
        guard let dir = ungrantedDocumentFolder,
              Self.promptedFolders.insert(dir.path).inserted else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else {
                Self.promptedFolders.remove(dir.path)   // no window yet; retry on the next restyle
                return
            }
            self.requestFolderAccess()
        }
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
        panel.prompt = "Allow"
        panel.message = "Edmund needs access to \(dir.lastPathComponent) to show its images and linked notes."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            FolderAccess.grant(url)
            self?.recomposeAllDirty()
            then?()
        }
    }
}
