import Testing
import Foundation
@testable import EdmundCore

/// The sandbox folder-grant store. Security-scoped bookmarks can't be created
/// or resolved outside a sandboxed process, so `swift test` covers the pure
/// matching and the unsandboxed no-op contract; the grant flow itself is on
/// the live checklist (sandboxed build, cmd+click a placeholder).
@Suite("Folder access")
struct FolderAccessTests {

    @Test("A grant covers the folder itself and anything below it")
    func coversNested() {
        let granted = ["/Users/x/Notes"]
        #expect(FolderAccess.folder(covering: "/Users/x/Notes", in: granted) == "/Users/x/Notes")
        #expect(FolderAccess.folder(covering: "/Users/x/Notes/pic.png", in: granted) == "/Users/x/Notes")
        #expect(FolderAccess.folder(covering: "/Users/x/Notes/deep/er/pic.png", in: granted) == "/Users/x/Notes")
    }

    @Test("Matching is on whole path components, not string prefixes")
    func wholeComponents() {
        let granted = ["/Users/x/Notes", "/Users/x/Other/"]
        #expect(FolderAccess.folder(covering: "/Users/x/Notes2/pic.png", in: granted) == nil)
        #expect(FolderAccess.folder(covering: "/Users/x/Other/pic.png", in: granted) == "/Users/x/Other/")
        #expect(FolderAccess.folder(covering: "/Users/x/pic.png", in: []) == nil)
    }

    @Test("Unsandboxed: every URL counts as covered")
    func unsandboxedCoversAll() {
        #expect(!FolderAccess.isSandboxed)
        #expect(FolderAccess.covers(URL(fileURLWithPath: "/nowhere/at/all.png")))
    }
}
