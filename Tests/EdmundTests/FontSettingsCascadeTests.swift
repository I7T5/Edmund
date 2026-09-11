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
    init() { ThemeScratch.activate() }


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

    /// One size for the whole preset: the standard size is the anchor, and
    /// the monospaced size and every per-script ratio keep their proportion to
    /// it. A scale that moved only the body would silently change the
    /// relationship between prose and code.
    @Test("Scaling every size keeps the faces in proportion")
    func scaleAllKeepsProportions() throws {
        let snapshot = snapshotThemeDefaults()
        defer { restoreThemeDefaults(snapshot) }

        let fonts = FontSettings()
        fonts.setStandardSize(16)
        fonts.setMonospaceSize(14)
        fonts.setCascadeFont(.han, family: "Helvetica")
        fonts.setCascadePointSize(.han, points: 20)   // ratio 1.25

        fonts.scaleAllSizes(toStandard: 20)

        #expect(fonts.standardFont.pointSize == 20)
        // 14 × 1.25 = 17.5, rounded to a whole point.
        #expect(fonts.monospaceFont.pointSize == 18)
        // The ratio is untouched, so the script follows the body on its own.
        #expect(fonts.cascadeSizeRatio(for: .han) == 1.25)
        #expect(fonts.cascadePointSize(for: .han) == 25)
    }

    @Test("The stepper's point range is the ratio clamp rendered against the body size")
    func stepperRangeTracksBodySize() {
        let snapshot = snapshotThemeDefaults()
        defer { restoreThemeDefaults(snapshot) }

        let fonts = FontSettings()
        fonts.setStandardSize(16)
        #expect(fonts.cascadePointSizeRange == 8...32)

        // The range moves with the body size, so the stepper can never offer
        // a point size the ratio clamp would refuse (8…72 did: body 20, 72 in,
        // 40 displayed — the up arrow live, the number frozen).
        fonts.setStandardSize(20)
        #expect(fonts.cascadePointSizeRange == 10...40)

        // Every value the range offers must survive the model round-trip
        // unclamped; check the ends and the midpoint.
        for points in [10.0, 20.0, 40.0] {
            fonts.setCascadePointSize(.han, points: points)
            #expect(fonts.cascadePointSize(for: .han) == points)
        }
    }

    @Test("Every row names a family and a size — the fallback's when unset")
    func cascadeSummaryShape() throws {
        let snapshot = snapshotThemeDefaults()
        defer { restoreThemeDefaults(snapshot) }

        let fonts = FontSettings()
        // Explicitly clear first — a dev machine may have a real Han cascade.
        fonts.setCascadeFont(.han, family: nil)
        fonts.setStandardSize(20)
        // An unset script still names something: the system fallback the editor
        // will really render it in, at the body size. The row greys it — the
        // sample beside it is what the script itself looks like. (Which family
        // that is depends on the host's installed fonts, so only the shape is
        // pinned here.)
        let unset = fonts.cascadeSummary(for: .han)
        #expect(!unset.isEmpty)
        #expect(unset.hasSuffix("  20"))
        #expect(unset != FontCascadeScript.han.sample)

        fonts.setCascadeFont(.han, family: "Helvetica")
        fonts.setCascadePointSize(.han, points: 25)
        let summary = fonts.cascadeSummary(for: .han)
        // The display name's localization is the host's business; the row's
        // contract is that the family is named and the point size is shown…
        #expect(summary.hasSuffix("  25"))
        // …and that the field draws at the size it names.
        #expect(try #require(fonts.previewFont(for: .han)).pointSize == 25)
    }
}
