import Testing
import Foundation
@testable import EdmundCore

/// The pure grouping/filtering logic behind the Clear Version History popup.
/// The NSFileVersion I/O in `VersionHistoryStore` needs the real system store,
/// so it isn't covered here — only the tree math, which must not need the disk.
@Suite("Version history")
struct VersionHistoryTests {

    let work = URL(fileURLWithPath: "/Users/x/Work")
    let notes = URL(fileURLWithPath: "/Users/x/Notes")

    func info(_ source: String, _ id: String, day: Int, size: Int64) -> VersionInfo {
        VersionInfo(id: URL(fileURLWithPath: id),
                    sourceURL: URL(fileURLWithPath: source),
                    date: Date(timeIntervalSince1970: TimeInterval(day) * 86_400),
                    size: size)
    }

    @Test("Groups folder → file → version and sums sizes bottom-up")
    func grouping() {
        let infos = [
            info("/Users/x/Work/spec.md",  "/v/a", day: 2, size: 100),
            info("/Users/x/Work/spec.md",  "/v/b", day: 1, size: 200),
            info("/Users/x/Work/notes.md", "/v/c", day: 1, size: 50),
            info("/Users/x/Notes/todo.md", "/v/d", day: 3, size: 400),
        ]
        let tree = buildVersionTree(infos)

        #expect(tree.count == 2)                       // Work + Notes
        let workFolder = try! #require(tree.first { $0.name == "Work" })
        #expect(workFolder.files.count == 2)           // spec.md + notes.md
        #expect(workFolder.versionCount == 3)          // 2 of spec.md + 1 of notes.md
        #expect(workFolder.size == 350)                // 100 + 200 + 50

        let spec = try! #require(workFolder.files.first { $0.name == "spec.md" })
        #expect(spec.size == 300)
        #expect(spec.versions.map(\.size) == [100, 200])   // newest (day 2) first
    }

    @Test("Search matches filename and filepath, case-insensitive; empty = passthrough")
    func filtering() {
        let tree = buildVersionTree([
            info("/Users/x/Work/spec.md",  "/v/a", day: 1, size: 1),
            info("/Users/x/Notes/todo.md", "/v/b", day: 1, size: 1),
        ])

        #expect(filterVersionTree(tree, query: "").count == 2)
        #expect(filterVersionTree(tree, query: "   ").count == 2)

        // Filename match keeps only the matching file.
        let byName = filterVersionTree(tree, query: "SPEC")
        #expect(byName.count == 1)
        #expect(byName.first?.files.first?.name == "spec.md")

        // Folder-path match keeps the whole folder.
        let byPath = filterVersionTree(tree, query: "notes")
        #expect(byPath.first?.name == "Notes")
    }

    @Test("Before-date cutoff selects strictly older versions")
    func cutoff() {
        let infos = [
            info("/f/a.md", "/v/a", day: 1, size: 1),
            info("/f/a.md", "/v/b", day: 5, size: 1),
        ]
        let cut = Date(timeIntervalSince1970: 3 * 86_400)
        let old = versions(olderThan: cut, in: infos)
        #expect(old.map(\.id) == [URL(fileURLWithPath: "/v/a")])
    }
}
