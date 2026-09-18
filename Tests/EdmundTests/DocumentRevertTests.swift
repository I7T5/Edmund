import Testing
import AppKit
@testable import edmd
@testable import EdmundCore

/// Regression for #293: reverting to the file on disk — AppKit's silent
/// re-read when another app changes a clean document, the Revert button on
/// its "changed by another application" sheet, File ▸ Revert To — went
/// through `read(from:ofType:)`, which only parks the text in
/// `pendingContent`. Nothing adopted it once the window was up, so the
/// editor kept the old text while the change count said "in sync", and the
/// next save wrote the stale buffer back over the other app's changes.
@MainActor
struct DocumentRevertTests {
    @Test("Revert pushes the re-read file into the editor and keeps the caret")
    func revertReloadsEditor() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("revert-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        try "one\ntwo\nthree\n".write(to: url, atomically: true, encoding: .utf8)

        let document = Document()
        document.editor = makeEditor()
        document.editor.loadContent("one\ntwo\nthree\n")
        document.editor.setSelectedRange(NSRange(location: 12, length: 0)) // inside "three"

        // The file shrinks under the open document.
        try "one\ntwo\n".write(to: url, atomically: true, encoding: .utf8)
        try document.revert(toContentsOf: url, ofType: "net.daringfireball.markdown")

        #expect(document.editor.rawSource == "one\ntwo\n")
        // Clamped to the new length rather than jumping back to the top.
        #expect(document.editor.selectedRange().location == 8)
        #expect(document.isDocumentEdited == false)
    }

    /// AppKit's file presenter only hears coordinated writes; a plain
    /// `write(to:)` (what CLI tools and most editors do) has to be picked up
    /// by the document's own kqueue watch.
    @Test("An uncoordinated write to the file reloads a clean document")
    func uncoordinatedWriteReloads() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        try "before\n".write(to: url, atomically: true, encoding: .utf8)

        let document = Document()
        document.editor = makeEditor()
        document.editor.loadContent("before\n")
        document.fileURL = url   // arms the watch
        document.fileModificationDate = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        // A second later so the modification date actually differs.
        RunLoop.main.run(until: Date().addingTimeInterval(1.1))
        try "after\n".write(to: url, atomically: true, encoding: .utf8)   // atomic = replace, like an editor
        let deadline = Date().addingTimeInterval(3)
        while document.editor.rawSource != "after\n", Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        #expect(document.editor.rawSource == "after\n")
    }

    @Test("An uncoordinated write leaves a document with unsaved changes alone")
    func uncoordinatedWriteKeepsDirtyEdits() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-dirty-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        try "before\n".write(to: url, atomically: true, encoding: .utf8)

        let document = Document()
        document.editor = makeEditor()
        document.editor.loadContent("before\n")
        document.fileURL = url
        document.fileModificationDate = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        document.updateChangeCount(.changeDone)

        RunLoop.main.run(until: Date().addingTimeInterval(1.1))
        try "after\n".write(to: url, atomically: true, encoding: .utf8)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        // AppKit's "changed by another application" sheet handles this case.
        #expect(document.editor.rawSource == "before\n")
        #expect(document.isDocumentEdited == true)
    }
}
