import Testing
import AppKit
import EdmundCore
@testable import edmd

/// FontSettings' cascade-row model: the Reset path (which must clear a
/// script's size ratio together with its family) and the points↔ratio bridge
/// the row's stepper edits. FontSettings persists via `EditorTheme.save()` on
/// every change — to UserDefaults.standard, with no injection seam — so each
/// test snapshots the keys `save()` writes and restores them afterwards.
/// Serialized: every test here shares that one defaults domain.
@MainActor
@Suite("Font settings — cascade rows", .serialized)
struct FontSettingsCascadeTests {

    /// The keys `EditorTheme.save()` writes (`EditorTheme.Keys` is private).
    private static let themeKeys = [
        "EditorFontName", "EditorFontSize",
        "EditorMonospaceFontName", "EditorMonospaceFontSize",
        "EditorStandardLigatures", "EditorMonospaceLigatures",
        "EditorAntialias", "EditorLinkBlueHex", "EditorCodeHex",
        "EditorMathOperatorHex", "EditorMathNumberHex",
        "EditorLineSpacing", "EditorParagraphSpacingBefore",
        "EditorFontCascade", "EditorFontCascadeSizeRatios",
    ]

    /// Snapshots every theme key (nil = absent) so a test can restore the
    /// user's real settings — and a clean machine's empty ones — on exit.
    private func snapshotThemeDefaults() -> [String: Any?] {
        let d = UserDefaults.standard
        return Dictionary(uniqueKeysWithValues: Self.themeKeys.map { ($0, d.object(forKey: $0)) })
    }

    private func restoreThemeDefaults(_ snapshot: [String: Any?]) {
        let d = UserDefaults.standard
        for (key, value) in snapshot {
            if let value { d.set(value, forKey: key) } else { d.removeObject(forKey: key) }
        }
    }

    @Test("Resetting a script's font also clears its size ratio")
    func resetClearsFamilyAndRatio() {
        let snapshot = snapshotThemeDefaults()
        defer { restoreThemeDefaults(snapshot) }

        let fonts = FontSettings()
        fonts.setCascadeFont(.han, family: "Helvetica")
        fonts.setCascadeSizeRatio(.han, ratio: 1.5)
        #expect(fonts.cascadeFonts[.han] == "Helvetica")
        #expect(fonts.cascadeSizeRatios[.han] == 1.5)

        fonts.setCascadeFont(.han, family: nil)
        #expect(fonts.cascadeFonts[.han] == nil)
        #expect(fonts.cascadeSizeRatios[.han] == nil)
        #expect(fonts.cascadeSizeRatio(for: .han) == 1.0)

        // No orphan survives a reload to silently re-apply on the next set —
        // this is what the next launch (and Read mode) would see.
        let reloaded = EditorTheme.load()
        #expect(reloaded.fontCascade[.han] == nil)
        #expect(reloaded.fontCascadeSizeRatios[.han] == nil)
    }

    @Test("The row's point stepper edits the ratio through the body size")
    func pointsBridgeRoundTrips() {
        let snapshot = snapshotThemeDefaults()
        defer { restoreThemeDefaults(snapshot) }

        let fonts = FontSettings()
        fonts.setStandardSize(20)

        fonts.setCascadePointSize(.han, points: 25)
        #expect(fonts.cascadeSizeRatios[.han] == 1.25)
        #expect(fonts.cascadePointSize(for: .han) == 25)

        // The ratio model clamps to 0.5…2.0; the displayed points snap back.
        fonts.setCascadePointSize(.han, points: 72)
        #expect(fonts.cascadeSizeRatios[.han] == 2.0)
        #expect(fonts.cascadePointSize(for: .han) == 40)

        // Landing back on the body size stores 1.0, i.e. unset.
        fonts.setCascadePointSize(.han, points: 20)
        #expect(fonts.cascadeSizeRatios[.han] == nil)
    }

    @Test("Unset rows show the script's sample; set rows show family and points")
    func cascadeSummaryShape() throws {
        let snapshot = snapshotThemeDefaults()
        defer { restoreThemeDefaults(snapshot) }

        let fonts = FontSettings()
        // Explicitly clear first — a dev machine may have a real Han cascade.
        fonts.setCascadeFont(.han, family: nil)
        #expect(fonts.cascadeSummary(for: .han) == FontCascadeScript.han.sample)

        fonts.setStandardSize(20)
        fonts.setCascadeFont(.han, family: "Helvetica")
        fonts.setCascadePointSize(.han, points: 25)
        let summary = fonts.cascadeSummary(for: .han)
        // The display name's localization is the host's business; the row's
        // contract is that the family is named and the point size is shown…
        #expect(summary != FontCascadeScript.han.sample)
        #expect(summary.hasSuffix("  25"))
        // …and that the field draws at the size it names.
        #expect(try #require(fonts.previewFont(for: .han)).pointSize == 25)
    }
}
