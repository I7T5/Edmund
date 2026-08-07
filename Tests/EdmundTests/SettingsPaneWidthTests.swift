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
        #expect(fittingWidth(AppearanceSettingsView(fonts: FontSettings())) == general)
        #expect(fittingWidth(FontCascadeSettingsView(fonts: FontSettings())) == general)
        #expect(fittingWidth(EditSettingsView()) == general)
        #expect(fittingWidth(SyntaxSettingsView()) == general)
        #expect(fittingWidth(KeyBindingsSettingsView()) == general)
        #expect(fittingWidth(ExtensionsSettingsView()) == general)
        #expect(fittingWidth(AdvancedSettingsView()) == general)
    }
}
