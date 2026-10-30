import Testing
import Foundation
@testable import EdmundCore

/// The folder sidebar's file tree, on a scratch directory.
@Suite("Folder item")
struct FolderItemTests {

    /// root/
    ///   b.md  a10.md  a2.md  image.png  README  .hidden.md  .DS_Store
    ///   docs/  guide.md  notes/  deep.md
    ///   .git/  HEAD
    private func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderItemTests-\(UUID().uuidString)")
        let fm = FileManager.default
        for dir in ["docs/notes", ".git"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        for file in ["b.md", "a10.md", "a2.md", "image.png", "README", ".hidden.md", ".DS_Store",
                     "docs/guide.md", "docs/notes/deep.md", ".git/HEAD"] {
            try Data().write(to: root.appendingPathComponent(file))
        }
        return root
    }

    private func names(_ nodes: [FolderItem]) -> [String] { nodes.map(\.name) }

    @Test("Folders first, then Finder name order; .DS_Store and .git never listed")
    func sortingAndExclusions() throws {
        let root = FolderItem(url: try makeTree())
        #expect(names(root.children(showingHidden: false))
                == ["docs", "a2.md", "a10.md", "b.md", "image.png", "README"])
        #expect(names(root.children(showingHidden: true))
                == ["docs", ".hidden.md", "a2.md", "a10.md", "b.md", "image.png", "README"])
    }

    @Test("Markdown, text and extensionless files are editable; images and folders are not")
    func editable() throws {
        let children = FolderItem(url: try makeTree()).children(showingHidden: false)
        let editable = Dictionary(uniqueKeysWithValues: children.map { ($0.name, $0.isEditable) })
        #expect(editable == ["docs": false, "a2.md": true, "a10.md": true, "b.md": true,
                             "image.png": false, "README": true])
    }

    @Test("Plain text opens; source code, JSON and scripts are not editable")
    func codeIsNotEditable() {
        func editable(_ name: String) -> Bool {
            FolderItem(url: URL(fileURLWithPath: "/nowhere/\(name)")).isEditable
        }
        #expect(editable("notes.txt"))
        #expect(editable("post.markdown"))
        for name in ["main.swift", "app.py", "index.js", "data.json", "build.sh", "page.html"] {
            #expect(!editable(name), "\(name)")
        }
    }

    @Test("A filter keeps matches and the folders leading to them")
    func filterKeepsAncestors() throws {
        let root = FolderItem(url: try makeTree())
        let shown = try #require(root.filter("DEEP", showingHidden: false))
        let docs = try #require(root.children(showingHidden: false).first)
        let notes = try #require(docs.children(showingHidden: false).first)
        let deep = try #require(notes.children(showingHidden: false).first)
        #expect(shown == [ObjectIdentifier(docs), ObjectIdentifier(notes), ObjectIdentifier(deep)])
        #expect(root.filter("", showingHidden: false) == nil)
    }

    @Test("A folder matching by name brings all its contents")
    func folderMatchShowsContents() throws {
        let root = FolderItem(url: try makeTree())
        let shown = try #require(root.filter("doc", showingHidden: false))
        // docs, guide.md, notes, deep.md
        #expect(shown.count == 4)
    }

    @Test("Reload picks up new entries and keeps existing nodes")
    func reloadKeepsNodes() throws {
        let url = try makeTree()
        let root = FolderItem(url: url)
        let docs = try #require(root.children(showingHidden: false).first)
        try Data().write(to: url.appendingPathComponent("c.md"))
        #expect(!names(root.children(showingHidden: false)).contains("c.md"))
        root.reload()
        #expect(names(root.children(showingHidden: false)).contains("c.md"))
        #expect(root.children(showingHidden: false).first === docs)
        #expect(root.item(at: url.appendingPathComponent("docs")) === docs)
    }
}
