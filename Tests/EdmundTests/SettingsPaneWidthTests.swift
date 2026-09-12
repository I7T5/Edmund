import Testing
import SwiftUI
import AppKit
@testable import edmd

/// Switching Settings tabs should only ever resize the window vertically, so
/// every pane has to report the same fitting width. `SettingsTabViewController`
/// sizes the window from each pane's `preferredContentSize`, and animates the
/// change — a pane of a different width makes the window visibly jump sideways.
@MainActor
@Suite("Settings pane width")
struct SettingsPaneWidthTests {
    init() { ThemeScratch.activate() }


    private func fittingWidth(_ view: some View) -> CGFloat {
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        hosting.view.layoutSubtreeIfNeeded()
        return hosting.view.fittingSize.width
    }

    @Test("Every pane is the same width")
    func panesShareOneWidth() {
        let general = fittingWidth(GeneralSettingsView())
        #expect(general == 600)
        #expect(fittingWidth(ThemesSettingsView()) == general)
        #expect(fittingWidth(EditSettingsView()) == general)
        #expect(fittingWidth(SyntaxSettingsView()) == general)
        #expect(fittingWidth(KeyBindingsSettingsView()) == general)
        #expect(fittingWidth(ExtensionsSettingsView()) == general)
        #expect(fittingWidth(AdvancedSettingsView()) == general)
    }

    /// The nine per-script rows must not widen the pane. They are always shown
    /// now — the section stopped being a disclosure — so this needs no setup;
    /// it is the row content, not its visibility, that threatens the width.
    ///
    /// (The hard 600pt frame in settingsPanePadding() means this can only catch
    /// structural regressions; overflow inside the frame is a visual check.)
    @Test("The per-script rows do not widen the Themes pane")
    func scriptRowsDoNotWidenThePane() {
        #expect(fittingWidth(ThemesSettingsView()) == 600)
    }
}
