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
    /// before the menu has ever been opened — validation only runs on open, and
    /// until then the item wears whatever title it was built with.
    ///
    /// Asserted against validation rather than a literal, so flipping the
    /// default cannot leave the shipped title behind.
    @Test func menuShipsTitledForTheDefaultState() {
        let original = UserDefaults.standard.object(forKey: AppSettings.Key.showFormatBar)
        defer { UserDefaults.standard.set(original, forKey: AppSettings.Key.showFormatBar) }
        UserDefaults.standard.removeObject(forKey: AppSettings.Key.showFormatBar)

        let shipped = ViewMenu.build().submenu?.items.first {
            $0.action == #selector(Document.toggleFormatBar(_:))
        }
        let validated = NSMenuItem(title: "",
                                   action: #selector(Document.toggleFormatBar(_:)),
                                   keyEquivalent: "")
        _ = Document().validateMenuItem(validated)
        #expect(shipped?.title == validated.title)
    }

    /// The bar is opt-in: it costs a strip of the window and everything on it
    /// is already on the Format menu.
    @Test func formatBarDefaultsHidden() {
        let original = UserDefaults.standard.object(forKey: AppSettings.Key.showFormatBar)
        defer { UserDefaults.standard.set(original, forKey: AppSettings.Key.showFormatBar) }
        UserDefaults.standard.removeObject(forKey: AppSettings.Key.showFormatBar)
        #expect(AppSettings.showFormatBar == false)
    }
}
