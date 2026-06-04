import Testing
import Foundation
@testable import MarkdownEditorCore

@Suite("StatusBarPrefs")
struct StatusBarPrefsTests {

    /// A fresh, isolated UserDefaults domain so tests don't touch the real one.
    private func freshDefaults() -> UserDefaults {
        let suite = "StatusBarPrefsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("Unconfigured defaults: auto-hide on, all fields shown")
    func defaultsWhenUnconfigured() {
        let prefs = StatusBarPrefs.load(from: freshDefaults())
        #expect(prefs.autoHide == true)
        #expect(prefs.showWords)
        #expect(prefs.showCharacters)
        #expect(prefs.showLocation)
        #expect(prefs.showLine)
        #expect(prefs.showLineEnding)
    }

    @Test("Save then load round-trips a custom configuration")
    func roundTrip() {
        let defaults = freshDefaults()
        var prefs = StatusBarPrefs()
        prefs.autoHide = false
        prefs.showCharacters = false
        prefs.showLineEnding = false
        prefs.save(to: defaults)

        let loaded = StatusBarPrefs.load(from: defaults)
        #expect(loaded == prefs)
        #expect(loaded.autoHide == false)
        #expect(loaded.showCharacters == false)
        #expect(loaded.showLineEnding == false)
        #expect(loaded.showWords)
    }

    @Test("A saved all-false config is not mistaken for defaults")
    func allFalsePersists() {
        let defaults = freshDefaults()
        let prefs = StatusBarPrefs(autoHide: false, showWords: false,
                                   showCharacters: false, showLocation: false,
                                   showLine: false, showLineEnding: false)
        prefs.save(to: defaults)

        let loaded = StatusBarPrefs.load(from: defaults)
        // Without the "configured" flag this would fall back to the all-shown defaults.
        #expect(loaded == prefs)
        #expect(loaded.showWords == false)
    }
}
