import Testing
import AppKit
@testable import edmd

/// The View menu's format-bar item names the action it will perform, flipping
/// with the setting — the same idiom as Hide/Show Toolbar beside it, rather
/// than a checkmark on a fixed title.
@MainActor @Suite("View menu titles")
struct ViewMenuTitleTests {

    @Test func formatBarItemNamesTheActionItWillPerform() {
        let document = Document()
        let item = NSMenuItem(title: "",
                              action: #selector(Document.toggleFormatBar(_:)),
                              keyEquivalent: "")
        let original = AppSettings.showFormatBar
        defer { AppSettings.showFormatBar = original }

        AppSettings.showFormatBar = true
        _ = document.validateMenuItem(item)
        #expect(item.title == "Hide Format Bar")

        AppSettings.showFormatBar = false
        _ = document.validateMenuItem(item)
        #expect(item.title == "Show Format Bar")
    }

    /// The item ships titled for the default state, so it reads correctly
    /// before the menu has ever been opened (validation only runs on open).
    @Test func menuShipsTitledForTheDefaultState() {
        let original = AppSettings.showFormatBar
        defer { AppSettings.showFormatBar = original }
        AppSettings.showFormatBar = true

        let item = ViewMenu.build().submenu?.items.first {
            $0.action == #selector(Document.toggleFormatBar(_:))
        }
        #expect(item?.title == "Hide Format Bar")
    }
}
