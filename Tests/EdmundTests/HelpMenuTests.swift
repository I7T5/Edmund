import Testing
import AppKit
@testable import edmd

/// The Help menu's order, divider, and link targets. Acknowledgments is absent
/// here: the test runner has no bundled Acknowledgments.html.
@MainActor @Suite("Help menu")
struct HelpMenuTests {

    @Test func itemsAreInOrderWithTheirLinks() throws {
        let menu = try #require(HelpMenu.build().submenu)
        let titles = menu.items.map { $0.isSeparatorItem ? "---" : $0.title }
        #expect(titles == ["Edmund Help", "Key Bindings", "---",
                           "App Icons", "Release Notes", "Report a Bug\u{2026}",
                           "Star on GitHub", "Website"])

        let links = menu.items.compactMap { ($0.representedObject as? URL)?.absoluteString }
        #expect(links == ["https://edmund.md/icons",
                          "https://github.com/I7T5/Edmund/releases",
                          "https://github.com/I7T5/Edmund/issues/new?template=bug_report.md",
                          "https://github.com/I7T5/Edmund",
                          "https://edmund.md"])
    }

    /// Key Bindings lands on the Key Bindings pane, not wherever
    /// Settings was left.
    @Test func keyboardShortcutsSelectsKeyBindingsPane() throws {
        ThemeScratch.activate()
        let controller = SettingsWindowController()
        controller.selectPane(label: "Key Bindings")
        let tabs = try #require(controller.contentViewController as? NSTabViewController)
        #expect(tabs.tabViewItems[tabs.selectedTabViewItemIndex].label == "Key Bindings")
        #expect(controller.window?.title == "Key Bindings")
    }
}
