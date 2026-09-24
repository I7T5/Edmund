import Testing
import AppKit
@testable import edmd

/// File ▸ Save and Duplicate retitle per document, the way Pages and TextEdit do.
@MainActor @Suite("File menu titles")
struct FileMenuTitleTests {

    /// "Save…" while untitled (the save panel follows), plain "Save" on disk.
    @Test func saveCarriesAnEllipsisOnlyWhileUntitled() {
        let document = Document()
        let item = NSMenuItem(title: "", action: #selector(NSDocument.save(_:)), keyEquivalent: "")

        _ = document.validateMenuItem(item)
        #expect(item.title == "Save\u{2026}")

        document.fileURL = URL(fileURLWithPath: "/tmp/FileMenuTitleTests.md")
        _ = document.validateMenuItem(item)
        #expect(item.title == "Save")
    }

    /// Duplicate with Auto Save on; with it off the same item is Save As… and
    /// its ⌥ alternate, which would repeat it, hides.
    @Test func duplicateBecomesSaveAsWithoutAutoSave() {
        let original = UserDefaults.standard.object(forKey: AppSettings.Key.autoSaveWithVersions)
        defer { UserDefaults.standard.set(original, forKey: AppSettings.Key.autoSaveWithVersions) }

        let document = Document()
        let item = NSMenuItem(title: "", action: #selector(Document.duplicateOrSaveAs(_:)),
                              keyEquivalent: "")
        let alternate = NSMenuItem(title: "Save As\u{2026}", action: #selector(NSDocument.saveAs(_:)),
                                   keyEquivalent: "")
        alternate.isAlternate = true

        AppSettings.autoSaveWithVersions = true
        _ = document.validateMenuItem(item)
        _ = document.validateMenuItem(alternate)
        #expect(item.title == "Duplicate")
        #expect(!alternate.isHidden)

        AppSettings.autoSaveWithVersions = false
        _ = document.validateMenuItem(item)
        _ = document.validateMenuItem(alternate)
        #expect(item.title == "Save As\u{2026}")
        #expect(alternate.isHidden)
    }
}
