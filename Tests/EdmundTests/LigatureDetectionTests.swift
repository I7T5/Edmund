import Testing
import AppKit
@testable import EdmundCore

/// `hasLigatures` decides whether the Ligatures checkbox is live, and it asks by
/// shaping rather than by reading the font's feature table — every face tested
/// advertises the ligature feature, Monaco and Menlo included, neither of which
/// has one. These pin that it still discriminates.
@Suite("Ligature detection")
@MainActor
struct LigatureDetectionTests {

    /// Skipped rather than failed if the host lacks either face: which fonts
    /// ship with macOS is not this repo's business, and a test that fails on a
    /// future OS for that reason teaches nothing.
    @Test("A serif with fi/fl reads as having ligatures; a plain mono does not")
    func discriminates() throws {
        guard let serif = NSFont(name: "Iowan Old Style", size: 16),
              let mono = NSFont(name: "Monaco", size: 14)
        else { return }

        #expect(EditorTheme.hasLigatures(serif))
        #expect(EditorTheme.hasLigatures(mono) == false)
    }

    /// The reason the feature table was abandoned: it says yes to everything.
    /// If this ever starts failing, the table became usable and the shaping
    /// test could be retired.
    @Test("The font feature table cannot tell these two apart")
    func featureTableIsUseless() throws {
        guard let serif = NSFont(name: "Iowan Old Style", size: 16),
              let mono = NSFont(name: "Monaco", size: 14)
        else { return }

        func advertisesLigatures(_ font: NSFont) -> Bool {
            let features = CTFontCopyFeatures(font) as? [[String: Any]] ?? []
            return features.contains {
                $0[kCTFontFeatureTypeIdentifierKey as String] as? Int == kLigaturesType
            }
        }
        #expect(advertisesLigatures(serif))
        #expect(advertisesLigatures(mono))
    }

    /// Size cannot change the answer — the checkbox must not flicker as the
    /// theme's size is edited.
    @Test("The answer does not depend on point size")
    func sizeIndependent() throws {
        guard NSFont(name: "Iowan Old Style", size: 16) != nil else { return }
        for size in [8.0, 16.0, 72.0] {
            let font = try #require(NSFont(name: "Iowan Old Style", size: size))
            #expect(EditorTheme.hasLigatures(font))
        }
    }
}
