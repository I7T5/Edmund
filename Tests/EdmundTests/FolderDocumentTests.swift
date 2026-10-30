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

    @Test("Switching files closes a clean one and keeps one with unsaved changes")
    func switching() throws {
        let url = try makeFolder(["a.md": "# A", "b.md": "# B", "c.md": "# C"])
        let folder = try openFolder(url)
        defer { folder.windowController.window?.close() }

        folder.open(url.appendingPathComponent("a.md"))
        let a = try #require(folder.current)
        #expect(a.editor.string == "# A")
        #expect(folder.windowController.document === a)

        folder.open(url.appendingPathComponent("b.md"))
        let b = try #require(folder.current)
        #expect(b !== a)
        #expect(!folder.files.contains { $0 === a })
        #expect(folder.windowController.document === b)

        b.updateChangeCount(.changeDone)
        folder.open(url.appendingPathComponent("c.md"))
        #expect(folder.files.contains { $0 === b })
        #expect(folder.windowController.window?.isDocumentEdited == true)

        // Back to the edited file: the same document and editor, not a re-read.
        let editor = b.editor
        folder.open(url.appendingPathComponent("b.md"))
        #expect(folder.current === b)
        #expect(b.editor === editor)
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
        window.layoutIfNeeded()
        let content = try #require(window.contentView)
        let scroll = try #require(folder.current?.editor.enclosingScrollView)
        let editorTop = scroll.convert(scroll.bounds, to: content).maxY
        let sidebarTop = folder.windowController.fileBrowser.view.convert(
            folder.windowController.fileBrowser.view.bounds, to: content).maxY
        #expect(content.safeAreaInsets.top > 0)
        #expect(abs(editorTop - (content.bounds.height - content.safeAreaInsets.top)) < 1)
        #expect(abs(sidebarTop - content.bounds.height) < 1)
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
