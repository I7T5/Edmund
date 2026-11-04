import Testing
import AppKit
@testable import edmd
import EdmundCore

/// A folder window: files switched in one window, unsaved ones kept, the
/// sidebar following the disk. Builds the real window (sidebar, editor panes)
/// off screen.
@MainActor
@Suite("Folder document")
struct FolderDocumentTests {

    private func makeFolder(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderDocumentTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, text) in files {
            try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return root
    }

    private func openFolder(_ url: URL) throws -> FolderDocument {
        let folder = try FolderDocument(contentsOf: url, ofType: FolderDocument.typeName)
        folder.makeWindowControllers()
        return folder
    }

    private func settle(timeout: TimeInterval = 5, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !done() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    @Test("A directory is typed as a folder, a file inside it by extension")
    func typing() throws {
        let url = try makeFolder(["a.md": "# A"])
        #expect(DocumentController.contentType(of: url) == FolderDocument.typeName)
        #expect(DocumentController.contentType(of: url.appendingPathComponent("a.md"))
                == "net.daringfireball.markdown")
    }

    @Test("Switching files keeps the last few open, and every one with unsaved changes")
    func switching() throws {
        let names = (0...FolderDocument.keptFiles + 1).map { "\($0).md" }
        let url = try makeFolder(Dictionary(uniqueKeysWithValues: names.map { ($0, "# \($0)") }))
        let folder = try openFolder(url)
        defer { folder.windowController.window?.close() }

        folder.open(url.appendingPathComponent(names[0]))
        let first = try #require(folder.current)
        #expect(first.editor.string == "# 0.md")
        #expect(folder.windowController.document === first)
        first.updateChangeCount(.changeDone)

        folder.open(url.appendingPathComponent(names[1]))
        let second = try #require(folder.current)
        #expect(folder.windowController.document === second)

        // Back to a kept file: the same document and editor, not a re-read.
        let editor = first.editor
        folder.open(url.appendingPathComponent(names[0]))
        #expect(folder.current === first)
        #expect(first.editor === editor)

        // One more than the limit: the least recently shown clean file goes,
        // the edited one stays though it is older.
        for name in names.dropFirst(2) { folder.open(url.appendingPathComponent(name)) }
        #expect(folder.files.count == FolderDocument.keptFiles)
        #expect(!folder.files.contains { $0 === second })
        #expect(folder.files.contains { $0 === first })
        #expect(folder.windowController.window?.isDocumentEdited == true)
    }

    @Test("Each file has its own undo history")
    func undoPerFile() throws {
        let url = try makeFolder(["a.md": "# A", "b.md": "# B"])
        let folder = try openFolder(url)
        defer { folder.windowController.window?.close() }
        let window = try #require(folder.windowController.window)

        folder.open(url.appendingPathComponent("a.md"))
        let a = try #require(folder.current)
        #expect(window.undoManager === a.undoManager)
        a.updateChangeCount(.changeDone)   // keep it open
        folder.open(url.appendingPathComponent("b.md"))
        let b = try #require(folder.current)
        #expect(window.undoManager === b.undoManager)
        #expect(a.undoManager !== b.undoManager)
    }

    @Test("Closing the window closes the folder and every file in it")
    func closing() throws {
        let url = try makeFolder(["a.md": "# A", "b.md": "# B"])
        let folder = try openFolder(url)
        let controller = NSDocumentController.shared
        controller.addDocument(folder)

        folder.open(url.appendingPathComponent("a.md"))
        let a = try #require(folder.current)
        a.updateChangeCount(.changeDone)
        folder.open(url.appendingPathComponent("b.md"))
        let b = try #require(folder.current)
        #expect(controller.documents.contains { $0 === a })

        folder.windowController.window?.close()
        #expect(!controller.documents.contains { $0 === folder })
        #expect(!controller.documents.contains { $0 === a })
        #expect(!controller.documents.contains { $0 === b })
    }

    @Test("A file added on disk shows up in the sidebar")
    func watchesDisk() throws {
        let url = try makeFolder(["a.md": "# A"])
        let folder = try openFolder(url)
        defer { folder.windowController.window?.close() }
        let browser = folder.windowController.fileBrowser
        _ = browser.view
        #expect(browser.outlineView.numberOfRows == 1)

        try "new".write(to: url.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
        settle { browser.outlineView.numberOfRows == 2 }
        #expect(browser.outlineView.numberOfRows == 2)
    }

    /// The editor's own split view controller comes first in the responder
    /// chain; it must let the action through to the folder's.
    @Test("Toggle Sidebar from the editor reaches the folder window's sidebar")
    func toggleSidebar() throws {
        let url = try makeFolder(["a.md": "# A"])
        let folder = try openFolder(url)
        defer { folder.windowController.window?.close() }
        folder.open(url.appendingPathComponent("a.md"))
        let window = try #require(folder.windowController.window)
        #expect(window.firstResponder === folder.current?.editor)
        // Relative to the start: the split's autosave carries the state over
        // from earlier runs. Toggled twice, so it is left as found.
        let sidebar = folder.windowController.sidebar!
        let start = sidebar.isCollapsed

        let sent = window.firstResponder?.tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)),
                                                       with: nil) ?? false
        #expect(sent)
        settle(timeout: 2) { sidebar.isCollapsed != start }
        #expect(sidebar.isCollapsed != start)

        // The View menu's item, through the same chain, retitled for the state.
        let item = NSMenuItem(title: "", action: #selector(FolderWindowController.toggleFolderSidebar(_:)),
                              keyEquivalent: "")
        _ = folder.windowController.validateMenuItem(item)
        #expect(item.title == (sidebar.isCollapsed ? "Show Sidebar" : "Hide Sidebar"))
        #expect(window.firstResponder?.tryToPerform(item.action!, with: nil) == true)
        settle(timeout: 2) { sidebar.isCollapsed == start }
        #expect(sidebar.isCollapsed == start)
        _ = folder.windowController.validateMenuItem(item)
        #expect(item.title == (start ? "Show Sidebar" : "Hide Sidebar"))
    }

    @Test("The editor sits below the toolbar while the sidebar runs full height")
    func editorBelowToolbar() throws {
        let url = try makeFolder(["a.md": "# A"])
        let folder = try openFolder(url)
        defer { folder.windowController.window?.close() }
        folder.open(url.appendingPathComponent("a.md"))
        let window = try #require(folder.windowController.window)
        let content = try #require(window.contentView)
        let scroll = try #require(folder.current?.editor.enclosingScrollView)
        window.layoutIfNeeded()
        let editorTop = scroll.convert(scroll.bounds, to: content).maxY
        let sidebarTop = folder.windowController.fileBrowser.view.convert(
            folder.windowController.fileBrowser.view.bounds, to: content).maxY
        #expect(content.safeAreaInsets.top > 0)
        #expect(abs(editorTop - (content.bounds.height - content.safeAreaInsets.top)) < 1)
        #expect(abs(sidebarTop - content.bounds.height) < 1)
    }

    /// An inspector-behaviour item would cut the toolbar short above it in
    /// this full-size-content window; a plain one leaves it whole.
    @Test("A folder window's inspector is a plain split item that still toggles")
    func inspectorPlainItem() throws {
        let url = try makeFolder(["a.md": "# A"])
        let folder = try openFolder(url)
        defer { folder.windowController.window?.close() }
        folder.open(url.appendingPathComponent("a.md"))
        let a = try #require(folder.current)
        #expect(a.inspectorItem.behavior == .default)

        let window = try #require(folder.windowController.window)
        let start = a.inspectorItem.isCollapsed
        // The toolbar's info button, from the editor up the chain.
        #expect(window.firstResponder?.tryToPerform(#selector(NSSplitViewController.toggleInspector(_:)),
                                                    with: nil) == true)
        settle(timeout: 2) { a.inspectorItem.isCollapsed != start }
        #expect(a.inspectorItem.isCollapsed != start)
        // View ▸ Show/Hide Inspector.
        a.toggleInspectorShown(nil)
        settle(timeout: 2) { a.inspectorItem.isCollapsed == start }
        #expect(a.inspectorItem.isCollapsed == start)
    }

    /// Finder routes a folder to Edmund only through Info.plist: the Dock and
    /// Finder drops by the document type, its context menu by the service.
    @Test("Info.plist opens folders: a document type and the Open in Edmund service")
    func infoPlistTakesFolders() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Info.plist")
        let plist = try #require(NSDictionary(contentsOf: plistURL) as? [String: Any])
        let types = try #require(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        #expect(types.contains { ($0["LSItemContentTypes"] as? [String])?.contains("public.folder") == true })
        let services = try #require(plist["NSServices"] as? [[String: Any]])
        let open = try #require(services.first { $0["NSMessage"] as? String == "openInEdmund" })
        #expect((open["NSSendFileTypes"] as? [String])?.contains("public.folder") == true)

        // The Quick Action appex: an action extension shown in Finder, on folders.
        let actionURL = plistURL.deletingLastPathComponent()
            .appendingPathComponent("Resources/OpenFolderInfo.plist")
        let action = try #require(NSDictionary(contentsOf: actionURL) as? [String: Any])
        let ext = try #require(action["NSExtension"] as? [String: Any])
        #expect(ext["NSExtensionPointIdentifier"] as? String == "com.apple.ui-services")
        #expect(ext["NSExtensionPrincipalClass"] as? String == "EdmundOpenFolderAction")
        let attributes = try #require(ext["NSExtensionAttributes"] as? [String: Any])
        #expect(attributes["NSExtensionServiceAllowsFinderPreviewItem"] as? Bool == true)
        #expect((attributes["NSExtensionActivationRule"] as? String)?.contains("public.folder") == true)
    }

    @Test("Dimmed files can't be selected; folders and text files can")
    func dimmedNotSelectable() throws {
        let url = try makeFolder(["a.md": "", "pic.png": "", "main.swift": ""])
        try FileManager.default.createDirectory(at: url.appendingPathComponent("sub"),
                                                withIntermediateDirectories: false)
        let folder = try openFolder(url)
        defer { folder.windowController.window?.close() }
        let browser = folder.windowController.fileBrowser
        _ = browser.view
        var selectable: [String: Bool] = [:]
        for row in 0..<browser.outlineView.numberOfRows {
            let item = try #require(browser.outlineView.item(atRow: row) as? FolderItem)
            selectable[item.name] = browser.outlineView(browser.outlineView, shouldSelectItem: item)
        }
        #expect(selectable == ["sub": true, "a.md": true, "main.swift": false, "pic.png": false])
    }

    @Test("A file switched away from stops its background styling until it shows again")
    func hiddenFileStopsStyling() throws {
        let url = try makeFolder(["a.md": "# A", "b.md": "# B"])
        let folder = try openFolder(url)
        defer { folder.windowController.window?.close() }
        folder.open(url.appendingPathComponent("a.md"))
        let a = try #require(folder.current)
        folder.open(url.appendingPathComponent("b.md"))
        #expect(!a.editor.isEditorPresentationActive)
        #expect(folder.current?.editor.isEditorPresentationActive == true)
        folder.open(url.appendingPathComponent("a.md"))
        #expect(a.editor.isEditorPresentationActive)
    }

    @Test("A settings change closes the kept files, not the showing or edited ones")
    func settingsDropKeptFiles() throws {
        let url = try makeFolder(["a.md": "# A", "b.md": "# B", "c.md": "# C"])
        let folder = try openFolder(url)
        defer { folder.windowController.window?.close() }
        folder.open(url.appendingPathComponent("a.md"))
        let a = try #require(folder.current)
        a.updateChangeCount(.changeDone)
        folder.open(url.appendingPathComponent("b.md"))
        let b = try #require(folder.current)
        folder.open(url.appendingPathComponent("c.md"))
        let c = try #require(folder.current)

        // What `Document.restylableDocuments` does for each registered folder.
        folder.dropKeptFiles()
        #expect(folder.files.count == 2)
        #expect(folder.files.contains { $0 === a } && folder.files.contains { $0 === c })
        #expect(!folder.files.contains { $0 === b })
    }

    @Test("New File and New Folder create Finder-numbered items; the new file opens")
    func newItems() throws {
        let url = try makeFolder(["a.md": ""])
        let folder = try openFolder(url)
        defer { folder.windowController.window?.close() }
        let browser = folder.windowController.fileBrowser
        _ = browser.view

        browser.newFile(nil)
        #expect(folder.current?.fileURL?.lastPathComponent == "Untitled.md")
        browser.newFile(nil)
        #expect(folder.current?.fileURL?.lastPathComponent == "Untitled 2.md")
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("Untitled.md").path))

        // The selection is now a file at the top, so the folder goes there too.
        browser.newFolder(nil)
        var isFolder: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("untitled folder").path,
                                               isDirectory: &isFolder) && isFolder.boolValue)
        let selected = browser.outlineView.item(atRow: browser.outlineView.selectedRow) as? FolderItem
        #expect(selected?.name == "untitled folder")
    }

    // MARK: - File operations

    private func row(_ browser: FileBrowserViewController, _ name: String) -> FolderItem? {
        (0..<browser.outlineView.numberOfRows).lazy
            .compactMap { browser.outlineView.item(atRow: $0) as? FolderItem }
            .first { $0.name == name }
    }

    private func key(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = [],
                     in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    /// Deletes a trashed test file from the real Trash.
    private func emptyFromTrash(_ name: String) {
        let trash = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
        if let item = trash?.appendingPathComponent(name) { try? FileManager.default.removeItem(at: item) }
    }

    @Test("Return renames the row in place; the open file follows it, and the subtitle too")
    func renameInPlace() throws {
        let url = try makeFolder(["a.md": "# A"])
        let folder = try openFolder(url)
        defer { folder.windowController.window?.close() }
        let window = try #require(folder.windowController.window)
        let browser = folder.windowController.fileBrowser
        folder.open(url.appendingPathComponent("a.md"))
        let a = try #require(folder.current)

        browser.outlineView.keyDown(with: key(36, "\r", in: window))
        let editor = try #require(window.firstResponder as? NSTextView)
        #expect(editor.selectedRange() == NSRange(location: 0, length: 1))   // "a", not ".md"
        editor.insertText("renamed", replacementRange: editor.selectedRange())
        window.makeFirstResponder(browser.outlineView)   // ends the edit, as Return does

        let renamed = url.appendingPathComponent("renamed.md")
        #expect(FileManager.default.fileExists(atPath: renamed.path))
        settle { a.fileURL?.lastPathComponent == "renamed.md" }
        #expect(a.fileURL?.lastPathComponent == "renamed.md")
        #expect(window.subtitle == "renamed.md")
        #expect(row(browser, "renamed.md") != nil)
    }

    @Test("Escape leaves the name as it was")
    func renameCancelled() throws {
        let url = try makeFolder(["a.md": ""])
        let folder = try openFolder(url)
        defer { folder.windowController.window?.close() }
        let window = try #require(folder.windowController.window)
        let browser = folder.windowController.fileBrowser
        _ = browser.view
        let item = try #require(row(browser, "a.md"))

        browser.beginRename(item)
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText("zzz", replacementRange: editor.selectedRange())
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))

        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("a.md").path))
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent("zzz.md").path))
        let cell = browser.outlineView.view(atColumn: 0, row: browser.outlineView.row(forItem: item),
                                            makeIfNecessary: false) as? NSTableCellView
        #expect(cell?.textField?.stringValue == "a.md")
        #expect(window.firstResponder === browser.outlineView)
    }

    @Test("Duplicate copies the row beside itself and selects the copy")
    func duplicateRow() throws {
        let url = try makeFolder(["a.md": "text"])
        let folder = try openFolder(url)
        defer { folder.windowController.window?.close() }
        let browser = folder.windowController.fileBrowser
        _ = browser.view
        browser.duplicate(try #require(row(browser, "a.md")))
        let copy = url.appendingPathComponent("a copy.md")
        #expect((try? String(contentsOf: copy, encoding: .utf8)) == "text")
        let selected = browser.outlineView.item(atRow: browser.outlineView.selectedRow) as? FolderItem
        #expect(selected?.name == "a copy.md")
    }

    @Test("Command-Delete trashes the showing file and closes it; not one with unsaved changes")
    func trashRows() throws {
        let clean = "trash-\(UUID().uuidString).md"
        let edited = "keep-\(UUID().uuidString).md"
        let url = try makeFolder([clean: "", edited: ""])
        defer { emptyFromTrash(clean); emptyFromTrash(edited) }
        let folder = try openFolder(url)
        defer { folder.windowController.window?.close() }
        let window = try #require(folder.windowController.window)
        let browser = folder.windowController.fileBrowser

        folder.open(url.appendingPathComponent(edited))
        folder.current?.updateChangeCount(.changeDone)
        let editedItem = try #require(row(browser, edited))
        browser.trash(editedItem)   // refused: a beep, nothing moves
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent(edited).path))
        let menuItem = NSMenuItem(title: "Move to Trash", action: #selector(FileBrowserViewController.trashItem(_:)),
                                  keyEquivalent: "")
        browser.outlineView.selectRowIndexes([browser.outlineView.row(forItem: editedItem)], byExtendingSelection: false)
        #expect(!browser.validateMenuItem(menuItem))

        folder.open(url.appendingPathComponent(clean))
        let shown = try #require(folder.current)
        browser.outlineView.selectRowIndexes([browser.outlineView.row(forItem: try #require(row(browser, clean)))],
                                             byExtendingSelection: false)
        browser.outlineView.keyDown(with: key(51, "\u{7F}", .command, in: window))
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent(clean).path))
        #expect(!folder.files.contains { $0 === shown })
        #expect(folder.current == nil)
        #expect(row(browser, clean) == nil)
    }

    @Test("The filter lists matches and the folders above them")
    func filtering() throws {
        let url = try makeFolder(["a.md": "", "b.md": ""])
        try FileManager.default.createDirectory(at: url.appendingPathComponent("sub"),
                                                withIntermediateDirectories: false)
        try "".write(to: url.appendingPathComponent("sub/apple.md"), atomically: true, encoding: .utf8)
        let folder = try openFolder(url)
        defer { folder.windowController.window?.close() }
        let browser = folder.windowController.fileBrowser
        _ = browser.view

        browser.filterField.stringValue = "a"
        browser.filterChanged(nil)
        let rows = (0..<browser.outlineView.numberOfRows).compactMap {
            (browser.outlineView.item(atRow: $0) as? FolderItem)?.name
        }
        #expect(rows == ["sub", "apple.md", "a.md"])
    }
}
