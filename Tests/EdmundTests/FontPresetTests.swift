import Testing
import AppKit
@testable import EdmundCore
@testable import edmd

/// Font presets are a saved typographic setup, chosen in Settings ▸ Appearance.
/// They are deliberately *not* a theme kind an editor theme names — that
/// relation is what let a light↔dark switch change the reader's typeface — so
/// what these cover is the round trip: settings → preset → settings.
@Suite("Font presets", .serialized)
@MainActor
struct FontPresetTests {

    /// `UserDefaults.standard` and `ThemeStore.shared` are process-global, so
    /// each test puts back what it found.
    private func withCleanSlate(_ body: () throws -> Void) rethrows {
        let d = UserDefaults.standard
        let keys = [AppSettings.Key.themeFont,
                    "EditorFontName", "EditorFontSize",
                    "EditorMonospaceFontName", "EditorMonospaceFontSize",
                    "EditorLineSpacing", "EditorFontCascade", "EditorFontCascadeSizeRatios"]
        let saved = keys.map { ($0, d.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { d.set(value, forKey: key) } else { d.removeObject(forKey: key) }
            }
            ThemeStore.shared.reload()
        }
        for key in keys { d.removeObject(forKey: key) }
        try body()
    }

    @Test("The shipped preset holds exactly what the app ships with")
    func iowanMatchesTheShippedDefault() throws {
        let iowan = try #require(ThemeStore.shared.fontThemes().first { $0.name == "iowan" })
        // The whole point of the shipped preset: choosing it changes nothing.
        // Compared as applied, so every field a preset carries counts — the
        // monospace face included, where an empty name is the real shipped
        // value (Input Mono Narrow, then Input Mono, then the system face) and
        // a named one would quietly switch it.
        #expect(EditorTheme.default.applying(iowan) == EditorTheme.default)
        // The body face has to *resolve*, not merely decode: one this Mac cannot
        // load falls back silently and the preset would draw as something else.
        #expect(NSFont(name: iowan.fontName, size: 12) != nil)
    }

    /// Choosing a preset writes its values into the `Editor*` keys rather than
    /// being layered at render — which is what leaves `applyTheme` able to set
    /// a font at all.
    @Test("Applying a preset lands in the settings")
    func applyingLandsInSettings() throws {
        try withCleanSlate {
            let helvetica = try #require(
                ThemeStore.shared.fontThemes().first { $0.name == "helvetica-neue" })
            let fonts = FontSettings()
            fonts.apply(preset: helvetica)

            let loaded = EditorTheme.load()
            #expect(loaded.fontName == helvetica.fontName)
            #expect(loaded.monospaceFontName == helvetica.monospaceFontName)
            #expect(abs(Double(loaded.fontSize) - helvetica.fontSize) < 0.0001)
        }
    }

    /// Choosing is not editing. `ThemeStore.save` always writes to the user
    /// directory, so a stray write-back while applying would shadow the bundled
    /// file — the preset would show up as an edited built-in for no reason.
    @Test("Choosing a bundled preset does not shadow it")
    func choosingDoesNotShadow() throws {
        try withCleanSlate {
            let helvetica = try #require(
                ThemeStore.shared.fontThemes().first { $0.name == "helvetica-neue" })
            #expect(ThemeStore.shared.isUserTheme("helvetica-neue") == false)

            FontSettings().apply(preset: helvetica)
            ThemeStore.shared.reload()

            #expect(ThemeStore.shared.isUserTheme("helvetica-neue") == false)
        }
    }

    /// The other direction: an edit made while a preset is named is written
    /// into it, so the picker's name always describes what is on screen.
    @Test("An edit writes through to the named preset")
    func editsWriteThrough() throws {
        try withCleanSlate {
            let name = "test-preset-\(UUID().uuidString.prefix(8))"
            let seed = EditorTheme.default.fontTheme(name: name, displayName: "Test")
            try ThemeStore.shared.save(seed)
            defer {
                try? ThemeStore.shared.deleteUserTheme(named: name)
                ThemeStore.shared.reload()
            }

            let fonts = FontSettings()
            fonts.editingPreset = name
            fonts.setLineHeight(1.8)

            let updated = try #require(
                ThemeStore.shared.fontThemes().first { $0.name == name })
            #expect(abs(updated.lineHeight - 1.8) < 0.0001)
        }
    }

    /// The upgrade path. Someone whose fonts differ from the shipped ones must
    /// not have them replaced by a bundled preset on first launch.
    @Test("Changed fonts are captured as a preset rather than dropped")
    func changedFontsAreSeeded() throws {
        try withCleanSlate {
            UserDefaults.standard.set("Courier", forKey: "EditorMonospaceFontName")
            ThemeStore.shared.reload()

            AppSettings.migrateFontThemeSelection()

            let name = AppSettings.fontTheme
            defer {
                try? ThemeStore.shared.deleteUserTheme(named: name)
                ThemeStore.shared.reload()
            }
            #expect(name != AppSettings.DefaultTheme.font)
            let seeded = try #require(ThemeStore.shared.fontThemes().first { $0.name == name })
            #expect(seeded.monospaceFontName == "Courier")
        }
    }

    @Test("Untouched fonts are pointed at the shipped preset")
    func untouchedFontsSelectTheShippedPreset() {
        withCleanSlate {
            AppSettings.migrateFontThemeSelection()
            #expect(AppSettings.fontTheme == AppSettings.DefaultTheme.font)
        }
    }
}
